-- Unit test for the SDK's binary WS sub-protocol (asobi_ws_binary).
-- Run: cd asobi-defold && lua tests/test_binary.lua
--
-- Builds raw binary frames (`<<Type:8, Len:32/big, Payload:Len>>`) exactly
-- as the backend emits them and asserts they route through the same
-- entity-sync / terrain paths as the JSON messages.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

-- Minimal JSON decoder for flat objects of numbers/strings/bools — enough
-- for the FieldsJSON blobs a binary entity_delta carries.
local function json_decode(s)
	local pos = 1
	local function skip_ws()
		while pos <= #s do
			local c = s:byte(pos)
			if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
		end
	end
	local parse
	local function parse_string()
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1; return table.concat(out) end
			out[#out + 1] = c
			pos = pos + 1
		end
		error("unterminated string")
	end
	local function parse_number()
		local start = pos
		while pos <= #s do
			local c = s:byte(pos)
			if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69 then
				pos = pos + 1
			else break end
		end
		return tonumber(s:sub(start, pos - 1))
	end
	local function parse_object()
		pos = pos + 1
		local out = {}
		skip_ws()
		if s:sub(pos, pos) == "}" then pos = pos + 1; return out end
		while true do
			skip_ws()
			local k = parse_string()
			skip_ws()
			pos = pos + 1 -- ':'
			skip_ws()
			out[k] = parse()
			skip_ws()
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "}" then pos = pos + 1; return out
			else error("bad object") end
		end
	end
	local function parse_array()
		pos = pos + 1
		local out = {}
		skip_ws()
		if s:sub(pos, pos) == "]" then pos = pos + 1; return out end
		while true do
			skip_ws()
			out[#out + 1] = parse()
			skip_ws()
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "]" then pos = pos + 1; return out
			else error("bad array") end
		end
	end
	parse = function()
		skip_ws()
		local c = s:sub(pos, pos)
		if c == "{" then return parse_object()
		elseif c == "[" then return parse_array()
		elseif c == '"' then return parse_string()
		elseif c == "t" then pos = pos + 4; return true
		elseif c == "f" then pos = pos + 5; return false
		elseif c == "n" then pos = pos + 4; return nil
		else return parse_number() end
	end
	return parse()
end

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.json = {encode = function() return "" end, decode = json_decode}
_G.http = {request = function() end}
_G.hash = function(x) return x end

local realtime = require("asobi.realtime")

local failures = 0
local function check(cond, msg)
	if not cond then
		print("FAIL: " .. msg)
		failures = failures + 1
	end
end

local function new_rt()
	return realtime.new({ws_url = "ws://stub", access_token = ""})
end

-- Big-endian packers.
local function u8(n) return string.char(n & 0xFF) end
local function u16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function u32(n)
	return string.char((n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF)
end
local function i32(n)
	if n < 0 then n = n + 0x100000000 end
	return u32(n)
end
local function u64(n)
	local out = {}
	for i = 7, 0, -1 do out[#out + 1] = string.char((n >> (i * 8)) & 0xFF) end
	return table.concat(out)
end
local function frame(btype, payload)
	return u8(btype) .. u32(#payload) .. payload
end
local function delta(op_byte, id, fields_json)
	return u8(op_byte) .. u16(#id) .. id .. u32(#fields_json) .. fields_json
end

-- ------------------------------------------------------------------
-- Test 1: binary entity_delta (0x02) add routes through the tick path.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local added, tick_seen
	rt:on("entity_added", function(id, state) added = {id = id, state = state} end)
	rt:on("tick", function(t) tick_seen = t end)

	local payload = u64(99) .. u32(1) .. delta(0, "p1", '{"x":120,"y":80}')
	rt:_handle_message(frame(0x02, payload))

	check(added ~= nil, "binary add fired entity_added")
	check(added.id == "p1", "binary add carries entity_id")
	check(added.state.x == 120 and added.state.y == 80, "binary add fields parsed from FieldsJSON")
	check(tick_seen == 99, "binary tick number propagated")
	check(rt.entities["p1"].x == 120, "binary add lands in registry")
end

-- ------------------------------------------------------------------
-- Test 2: binary update merges (partial-diff preserved), remove deletes.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_handle_message(frame(0x02, u64(1) .. u32(1) .. delta(0, "e1", '{"x":1,"y":2}')))

	local upd
	rt:on("entity_updated", function(id, state, changed) upd = {state = state, changed = changed} end)
	rt:_handle_message(frame(0x02, u64(2) .. u32(1) .. delta(1, "e1", '{"x":9}')))
	check(upd ~= nil, "binary update fired entity_updated")
	check(upd.state.x == 9 and upd.state.y == 2, "binary update merges, y preserved")
	check(#upd.changed == 1 and upd.changed[1] == "x", "binary update changed list is x only")

	local removed
	rt:on("entity_removed", function(id) removed = id end)
	rt:_handle_message(frame(0x02, u64(3) .. u32(1) .. delta(2, "e1", "")))
	check(removed == "e1", "binary remove fired entity_removed")
	check(rt.entities["e1"] == nil, "binary remove clears registry")
end

-- ------------------------------------------------------------------
-- Test 3: multiple deltas in one binary frame.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local n = 0
	rt:on("entity_added", function() n = n + 1 end)
	local payload = u64(5) .. u32(2)
		.. delta(0, "a", '{"x":1}')
		.. delta(0, "b", '{"x":2}')
	rt:_handle_message(frame(0x02, payload))
	check(n == 2, "both deltas in one binary frame applied")
	check(rt.entities["a"].x == 1 and rt.entities["b"].x == 2, "both entities in registry")
end

-- ------------------------------------------------------------------
-- Test 4: binary terrain_chunk (0x01) fires world_terrain with signed coords.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local seen
	rt:on("world_terrain", function(p) seen = p end)
	local payload = i32(-3) .. i32(7) .. "COMPRESSED"
	rt:_handle_message(frame(0x01, payload))
	check(seen ~= nil, "binary terrain fired world_terrain")
	check(seen.coords[1] == -3 and seen.coords[2] == 7, "signed chunk coords decoded")
	check(seen.data == "COMPRESSED", "raw compressed terrain payload passed through")
end

-- ------------------------------------------------------------------
-- Test 5: text JSON frames still route as before (no binary misfire).
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local added
	rt:on("entity_added", function(id) added = id end)
	rt:_handle_message('{"type":"world.tick","payload":{"tick":1,"updates":' ..
		'[{"op":"add","entity_id":"j1","fields":{"x":5}}]}}')
	check(added == "j1", "JSON text frame still parsed after binary sniffing added")
end

-- ------------------------------------------------------------------
if failures == 0 then
	print("OK: all binary-protocol tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end
