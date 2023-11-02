# mysql driver, based on luasocket

Fork of the ["resty.mysql"](https://github.com/openresty/lua-resty-mysql/blob/master/lib/resty/mysql.lua) module.

- Удалены зависимости от NGINX и Openresty. Модуль будет работать при наличии одного лишь luasocket.
- Добавлена поддержка connection pool с асинхронными (non-blocking) запросами (100k `SELECT 2 + 3` выполняется за 5.8 сек при `pool_size 5`, `workers 3`).
- [Официальная документация](https://github.com/openresty/lua-resty-mysql/blob/master/README.markdown) актуальна и продолжает работать.

---

## Examples

Примеры приведены с замерами скорости работы в разных вариациях. Результаты кажутся нелогичными, поэтому под примерами я объясняю почему

### simple example

Здесь все ровно так же, как в официальной документации. Я привожу пример сразу с замером скорости, поэтому он немного сложнее, чем минимально возможный.

```lua
local mysql_conn_opts = {
	host     = host,
	port     = port,
	user     = mysql_user,
	password = mysql_pass,
	database = mysql_db,
	charset  = "utf8mb4",
}

local mysql = require("mysql")


local db, db_err = mysql.new()
if not db then
	print("[mysql] failed to initialize mysql: ", db_err)
	return false, db_err
end

local con_ok, con_err, con_errcode, con_sqlstate = db:connect(mysql_conn_opts)
if not con_ok then
	print("[mysql] failed to connect: ", con_err, ": ", con_errcode, " ", con_sqlstate)
	return false, con_err
end

local now = require("socket").gettime
local start = now()

local repeats = 100000
for i = 1, repeats do
	local q_res, q_err, q_errcode, q_sqlstate = db:query("SELECT 2 + 3 as sum")
	-- print("q_res", i, repeats, q_err, q_errcode, q_sqlstate, q_res and q_res[1].sum)
	repeats = repeats - 1

	if repeats == 0 then
		print("done in", now() - start) -- 7 sec for 100k requests.
	end
end
```


### async requests

Если у вас установлен copas, то вы можете выполнять запросы асинхронно (non-blocking). В указанном примере самый минимум проверок на ошибки.

Здесь одновременно "спавнится" 100 соединений (корутин). Могут возникать ошибки "Too many connections", но алгоритм устроен так, что сразу идет новая попытка подключения, пока соединение не станет доступным.

```lua
local copas = require("copas")
local mysql = require("mysql")

local mysql_conn_opts = {
	host     = host,
	port     = port,
	user     = mysql_user,
	password = mysql_pass,
	database = mysql_db,
	charset  = "utf8mb4",
}

local function get_db(mysql_conn_opts)
	local db
	local con_ok, con_err
	while not con_ok do
		db = mysql.new() -- you need some checks for errors here. I skipped them for brevity
		db.sock = copas.wrap(db.sock) -- now the connection is non-blocking. Further use is only allowed inside copas.addthread

		con_ok, con_err = db:connect(mysql_conn_opts)
		-- if not con_ok then -- you can uncomment this for delay before new connection against ddosing your db
		-- 	print("[mysql] failed to connect: ", con_err)
		-- 	copas.sleep(1)
		-- end
	end
	return db
end


local function do_query(q, callback)
	copas.addnamedthread("mysql_async_query", function()
		local db = get_db(mysql_conn_opts)

		local q_res, q_err, q_errcode, q_sqlstate = db:query(q)
		callback(q_res, q_err, q_errcode, q_sqlstate)
	end)
end


local now = require("socket").gettime
local start = now()

local repeats = 100
for i = 1, repeats do
	do_query("SELECT 2 + 3 as sum", function(q_res, q_err, q_errcode, q_sqlstate)
		-- print("q_res", i, repeats, q_err, q_errcode, q_sqlstate, q_res and q_res[1].sum)
		repeats = repeats - 1

		if repeats == 0 then
			print("done in", now() - start) -- 100 requests for 1.8 sec with max_connections = 5 in mysql.cnf
		end
	end)
end

copas.loop()
```

### using connection polling

Это метод, при котором можно переиспользовать mysql соединения вместо создания новых. Также пул сам автоматически следит за тем, чтобы БД не "отвалилась" и переподключается к ней.

- Connection pooling требует [copas](https://github.com/lunarmodules/copas/tree/master) для выполнения асинхронных запросов. С модулем сам не устанавливается
- `pool:query(query, callback, timeout)` – основная функция. Выполняет запрос, само подбирает соединениеЮ результат возвращает в колбеке. При потере соединения с БД, через (timeout or 10) sec в колбеке вернет ошибку "timeout"
- Если теряется или не может создаться соединение с БД, то выполняется метод `pool:on_connection_error(err)`. Этот метод можно оверрайднуть, чтобы заменить внутри `copas.sleep(5)` (время повторной попытки подключения) и добавить свой логгинг вместо `print(err)`.

```lua
local pool = require("mysql.pool").new({
	pool_size = 5,
	workers   = 3,
	mysql_opts = {
		host      = host,
		port      = port,
		user      = mysql_user,
		password  = mysql_pass,
		database  = mysql_db,
		charset   = "utf8mb4"
	},
})

local now = require("socket").gettime
local start = now()

local repeats = 100000
for i = 1, repeats do
	pool:query("SELECT 2 + 3", function(q_res, q_err, q_errcode, q_sqlstate)
		repeats = repeats - 1

		if repeats == 0 then
			print("done in", now() - start) -- 🔥 100k for 6 sec
		end
	end, 5) -- timeout for waiting reconnection if database connection lost before request. Default 10
end

require("copas").loop()
```

## Why benchmarks seems strange?

1. Простые последовательные запросы 100k за 7 сек
2. Простые асинхронные запросы 100 (не тыс) за 2 сек
3. Connection pooling 100k за 6 сек

> Тесты проводились с локальной БД, настроенной на `max_connections = 5`, выполняя самый примитивный запрос.

1. Если бы в первом случае запросы были "как в реальной жизни" и какой-то из них занимал бы 2 сек, то все приложение зависло бы на 2 сек.
2. Если бы max_connections ровнялся бы кол-ву запросов, которые мы одновременно(!) выполняем, при этом каждый запрос выполнялся бы по 2 сек, то они выполнились бы **все** через 2 сек. К примеру, первый тест выполнял бы 100к запросов `100k * 2sec = 55 hours`
3. В третьем примере нам почти не важна `max_connections` настройка в БД. Он в любом случае будет самым быстрым. Будь запросы длительные или быстрые – это не имело бы значения.
