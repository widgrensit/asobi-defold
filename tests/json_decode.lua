-- Minimal JSON decoder - enough for the canonical fixture corpus.
--
-- Defold ships a `json` module, but these tests run in plain Lua outside the
-- engine, so they bring their own. Extracted here rather than copied a fourth
-- time; test_dispatch, test_binary and test_auth still carry their own copies
-- and can adopt this when they are next touched.
--
--   local json_decode = dofile("tests/json_decode.lua")

local json_decode
local json_decode
do
	local pos
	local skip_ws = function(s)
		while pos <= #s do
			local c = s:byte(pos)
			if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
		end
	end
	local parse
	local function parse_string(s)
		assert(s:sub(pos, pos) == '"', "expected '\"' at " .. pos)
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1; return table.concat(out)
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				if n == "n" then out[#out + 1] = "\n"
				elseif n == "t" then out[#out + 1] = "\t"
				elseif n == "r" then out[#out + 1] = "\r"
				elseif n == '"' then out[#out + 1] = '"'
				elseif n == "\\" then out[#out + 1] = "\\"
				elseif n == "/" then out[#out + 1] = "/"
				else out[#out + 1] = n end
				pos = pos + 2
			else
				out[#out + 1] = c
				pos = pos + 1
			end
		end
		error("unterminated string")
	end
	local function parse_number(s)
		local start = pos
		while pos <= #s do
			local c = s:byte(pos)
			if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69 then
				pos = pos + 1
			else break end
		end
		return tonumber(s:sub(start, pos - 1))
	end
	local function parse_literal(s, lit, val)
		if s:sub(pos, pos + #lit - 1) == lit then pos = pos + #lit; return val end
		error("bad literal at " .. pos)
	end
	local function parse_object(s)
		assert(s:sub(pos, pos) == "{")
		pos = pos + 1
		local out = {}
		skip_ws(s)
		if s:sub(pos, pos) == "}" then pos = pos + 1; return out end
		while true do
			skip_ws(s)
			local k = parse_string(s)
			skip_ws(s)
			assert(s:sub(pos, pos) == ":", "expected ':'")
			pos = pos + 1
			skip_ws(s)
			out[k] = parse(s)
			skip_ws(s)
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "}" then pos = pos + 1; return out
			else error("bad object at " .. pos) end
		end
	end
	local function parse_array(s)
		assert(s:sub(pos, pos) == "[")
		pos = pos + 1
		local out = {}
		skip_ws(s)
		if s:sub(pos, pos) == "]" then pos = pos + 1; return out end
		while true do
			skip_ws(s)
			out[#out + 1] = parse(s)
			skip_ws(s)
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "]" then pos = pos + 1; return out
			else error("bad array at " .. pos) end
		end
	end
	parse = function(s)
		skip_ws(s)
		local c = s:sub(pos, pos)
		if c == "{" then return parse_object(s)
		elseif c == "[" then return parse_array(s)
		elseif c == '"' then return parse_string(s)
		elseif c == "t" then return parse_literal(s, "true", true)
		elseif c == "f" then return parse_literal(s, "false", false)
		elseif c == "n" then return parse_literal(s, "null", nil)
		else return parse_number(s) end
	end
	json_decode = function(s) pos = 1; return parse(s) end
end


return json_decode
