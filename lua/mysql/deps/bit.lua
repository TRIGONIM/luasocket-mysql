---@diagnostic disable: duplicate-set-field, cast-local-type, param-type-mismatch

---@diagnostic disable-next-line: undefined-global
local bit = bit
if bit then return bit end

local bitok, bit_ = pcall(require, "bit")
if bitok then
	return bit_
end

local bit32ok, bit32 = pcall(require, "bit32")
if bit32ok then
	return bit32
end


local info = debug.getinfo(1, "Sl")
local has_bitwise, bitwise = pcall(load(("\n"):rep(info.currentline + 1) .. [[return {
	band   = function(a, b) return a & b end,
	bor    = function(a, b) return a | b end,
	bxor   = function(a, b) return a ~ b end,
	lshift = function(a, b) return a << b end,
	rshift = function(a, b) return a >> b end,
}]], info.source))
if has_bitwise then
	return bitwise
end

error("You need to install install bitwise library")
