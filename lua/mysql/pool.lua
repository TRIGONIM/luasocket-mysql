local copas = require("copas")
local mysql = require("mysql") -- luasocket-mysql

local POOL_MT = {}
POOL_MT.__index = POOL_MT

-- possible fields:
-- {
-- 	pool_size  = 5, -- max connections in pool. Required
-- 	workers    = 3, -- threads for queries processing. Default: 3
-- 	mysql_opts = {
-- 		host      = "ip.or.port",
-- 		port      = 3306,
-- 		user      = "username",
-- 		password  = "pass",
-- 		database  = "name",
-- 		charset   = "utf8mb4",
-- 	}
-- }
function POOL_MT.new(opts)
	local self = setmetatable({}, POOL_MT)
	self.opts = opts

	self.connections = copas.queue.new({name = "mysql_conn_pool"})
	self.queries     = copas.queue.new({name = "mysql_query_queue"})

	-- в том числе и используемые, которых в connections_pool сейчас может не быть
	-- при ошибке в запросе, соединение не пушится в connections_pool и это число уменьшается
	self.connections.waiting = copas.semaphore.new(opts.pool_size, opts.pool_size, math.huge) -- last arg is dafault timeout for :take

	self:_start_fill_connections()
	self:_start_queries_processing()

	return self
end

local new_connection = function(mysql_opts)
	local conn, err = mysql.new()
	if not conn then
		return false, err
	end

	conn.sock = copas.wrap(conn.sock)

	local con_ok, con_err, con_errcode, con_sqlstate = conn:connect(mysql_opts)
	if not con_ok then -- con_errcode и con_sqlstate наверное могут быть только при ошибке авторизации и Too many connections
		return false, con_err, con_errcode, con_sqlstate
	end

	return conn
end

-- Как new_connection, но не отстанет, пока не отдаст соединение, пусть хоть вечность пройдет
function POOL_MT:_wait_new_connection()
	local conn, err
	while not conn do
		conn, err = new_connection(self.opts.mysql_opts)
		if not conn then
			self:on_connection_error(err)
		end
	end
	return conn
end

-- Заполняет недостающие соединения
-- При создании пула, либо когда ошибка запроса и соединение вылетает из пула
function POOL_MT:_start_fill_connections()
	copas.addnamedthread("db_connect", function() while true do
		local need_connection, err = self.connections.waiting:take(1, math.huge) -- math.huge таймаут. Стопнет while true, пока не появится "запрос" на соединение
		if need_connection then
			local conn = self:_wait_new_connection()
			self.connections:push(conn)
		elseif err == "destroyed" then
			print("Semaphore destroyed. We no longer create new connections. I think it could only happen with manual sema:destroy()")
			return
		end
	end end)
end

function POOL_MT:run_query(q, timeout)
	-- timeout can "hang" a thread until there is a connection for the specified timeout
	-- this is possible if the database has disconnected and you have to wait for recovery
	local conn = self.connections:pop(timeout)
	if not conn then
		return false, "timeout"
	end

	local q_res, q_err, q_errcode, q_sqlstate = conn:query(q)
	if q_res then
		self.connections:push(conn) -- release the connection
		return q_res
	else
		-- if any problem with the request, then drop the connection (don't add it again),
		-- so connection will be recreated.
		-- Could be an invalid query, or the database disconnected (restart or something..)
		self.connections.waiting:give() -- here we say we're waiting for a new connection

		-- 2 possibles: if DB restarted, only self.state will be reset (useless).
		-- Else will send COM_QUIT and close socket.
		local ok, err = conn:close()
		if not ok then
			print("failed to close connection: ", err) -- может отпринтить, если БД отвалилась. То, что будет при sock:send(packet) (closed)
		end

		return false, q_err, q_errcode, q_sqlstate
	end
end

function POOL_MT:_start_queries_processing()
	for _ = 1, self.opts.workers do
		self.queries:add_worker(function(item)
			local q_res, q_err, q_errcode, q_sqlstate = self:run_query(item[1], item[3]) -- q, timeout
			local ok, res = pcall(item[2], q_res, q_err, q_errcode, q_sqlstate)
			if not ok then
				print("error in worker", res)
			end
		end)
	end
end

-- Выполняет запрос к БД. Если нет свободных соединений, то ждет (timeout or 10) секунд, пока появятся.
-- Если в запросе ошибка, то вернет false, err, errcode, sqlstate.
-- Если активных соединений для запроса не появляется, то вернет false, "timeout". Может быть, если БД отвалилась.
-- Если соединение отвалилось во время запроса, то вернет false, err. err может быть такими:
-- 	failed to receive packet header: closed
-- 	failed to send query: cannot send query in the current context: 2
function POOL_MT:query(q, callback, timeout)
	self.queries:push({q, callback, timeout})
end

-- override me if you want
function POOL_MT:on_connection_error(err)
	print("failed to connect to database. Waiting 5 sec. Error: " .. err)
	copas.sleep(5)
end
-- function POOL_MT:on_query_error() end -- #todo базовые логгинг. И решить, нужно ли сюда передавать ошибки от pcall в воркере


return POOL_MT
