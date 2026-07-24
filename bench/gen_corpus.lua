#!/usr/bin/env luajit
-- Deterministic corpus generator for collation benchmarks.
--
-- Usage: luajit gen_corpus.lua N [seed]
--   Emits exactly N lines of realistic, mixed content to stdout: words in
--   assorted cases, digit runs (for natural-sort stress), spaces and
--   punctuation separators, and a sprinkling of Latin-1/Extended-A accents.
--
-- The PRNG is a hand-rolled xorshift32 over the `bit` library so the corpus is
-- byte-for-byte identical on every machine/LuaJIT build (math.random is NOT
-- portable). Same (N, seed) => same corpus => comparable benchmark timings.

local bit = require("bit")
local buffer = require("string.buffer")

local N = tonumber(arg[1]) or 10000
local seed = tonumber(arg[2]) or 0x1234567
if seed == 0 then seed = 0x1234567 end

local s = bit.tobit(seed)
local function next32()
	s = bit.bxor(s, bit.lshift(s, 13))
	s = bit.bxor(s, bit.rshift(s, 17))
	s = bit.bxor(s, bit.lshift(s, 5))
	return bit.band(s, 0x7fffffff)
end
local function pick(t)
	return t[(next32() % #t) + 1]
end
local function chance(n) -- true with probability 1/n
	return (next32() % n) == 0
end

-- A small dictionary of realistic tokens.
local words = {
	"file", "report", "image", "document", "backup", "invoice", "photo",
	"chapter", "section", "note", "draft", "final", "summary", "index",
	"chart", "table", "figure", "appendix", "readme", "config", "data",
	"user", "admin", "guest", "project", "module", "widget", "sample",
	"cafe", "resume", "naive", "uber", "senor", "fiancee", "cliche",
	"Zebra", "apple", "Banana", "cherry", "Date", "Elderberry", "fig",
}

-- Accent substitutions applied occasionally to make diacritics matter.
local accents = {
	a = { "\195\160", "\195\161", "\195\162", "\195\164" }, -- à á â ä
	e = { "\195\168", "\195\169", "\195\170", "\195\171" }, -- è é ê ë
	i = { "\195\172", "\195\173", "\195\174", "\195\175" }, -- ì í î ï
	o = { "\195\178", "\195\179", "\195\180", "\195\182" }, -- ò ó ô ö
	u = { "\195\185", "\195\186", "\195\187", "\195\188" }, -- ù ú û ü
	n = { "\195\177" },                                     -- ñ
	c = { "\196\141", "\195\167" },                         -- č ç
	s = { "\197\161" },                                     -- š
	z = { "\197\190" },                                     -- ž
}

local seps = { " ", "-", "_", ".", ":", " - ", "/", " " }

local function accentize(w)
	-- Replace one eligible lowercase vowel/consonant with an accented form.
	local pos = {}
	for i = 1, #w do
		local ch = w:sub(i, i)
		if accents[ch] then pos[#pos + 1] = i end
	end
	if #pos == 0 then return w end
	local i = pos[(next32() % #pos) + 1]
	local ch = w:sub(i, i)
	local rep = pick(accents[ch])
	return w:sub(1, i - 1) .. rep .. w:sub(i + 1)
end

local function casify(w)
	local mode = next32() % 4
	if mode == 0 then
		return w:lower()
	elseif mode == 1 then
		return w:upper()
	elseif mode == 2 then
		return w:sub(1, 1):upper() .. w:sub(2):lower()
	else
		return w -- as-is (dictionary already has mixed case)
	end
end

local function token()
	local w = pick(words)
	w = casify(w)
	if chance(4) then w = accentize(w) end
	if chance(2) then
		-- append a digit run (natural-sort stress); vary magnitude
		local mag = pick({ 9, 99, 999, 9999 })
		w = w .. tostring(next32() % mag)
	end
	return w
end

local out = buffer.new(1048576)
for _ = 1, N do
	local ntok = 1 + (next32() % 3)
	local line = token()
	for _ = 2, ntok do
		line = line .. pick(seps) .. token()
	end
	out:put(line)
	out:put("\n")
	if #out > 524288 then
		io.write(out:tostring())
		out:reset()
	end
end
io.write(out:tostring())
