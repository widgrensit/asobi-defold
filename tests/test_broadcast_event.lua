-- `game.broadcast(name, payload)` from a Lua match or world script arrives as
-- `match.<name>` / `world.<name>`, where <name> is script-defined. There is no
-- fixture for it in the canonical corpus for that reason, so the frames are
-- built inline here.
--
-- Pure unit test, plain Lua 5.4:
--   lua5.4 tests/test_broadcast_event.lua

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

-- Enough of a decoder for the flat frames below.
_G.json = {
	encode = function() return "" end,
	decode = function(s)
		local mtype = s:match('"type"%s*:%s*"([^"]+)"')
		local value = tonumber(s:match('"value"%s*:%s*(%-?%d+)'))
		return {type = mtype, payload = {value = value}}
	end,
}

local realtime = require("asobi.realtime")

local failures = 0

local function check(cond, msg)
	if cond then
		print("  ok  " .. msg)
	else
		print("  FAIL " .. msg)
		failures = failures + 1
	end
end

local function new_rt()
	return realtime.new({ws_url = "ws://stub", access_token = ""})
end

do
	local rt = new_rt()
	local got_name, got_payload
	rt:on("match_event", function(name, payload)
		got_name, got_payload = name, payload
	end)
	rt:_handle_message('{"type":"match.players_total","payload":{"value":3}}')
	check(got_name == "players_total", "match.players_total -> match_event with the bare name")
	check(got_payload and got_payload.value == 3, "the payload reaches the callback intact")
end

do
	local rt = new_rt()
	local got_name, got_payload
	rt:on("world_event", function(name, payload)
		got_name, got_payload = name, payload
	end)
	rt:_handle_message('{"type":"world.players_total","payload":{"value":7}}')
	check(got_name == "players_total", "world.players_total -> world_event with the bare name")
	check(got_payload and got_payload.value == 7, "the payload reaches the callback intact")
end

-- A named event already has its own callback; firing the catch-all as well
-- would deliver every match.state twice to a game bound to both.
do
	local rt = new_rt()
	local named, generic = false, false
	rt:on("match_finished", function() named = true end)
	rt:on("match_event", function() generic = true end)
	rt:_handle_message('{"type":"match.finished","payload":{"value":1}}')
	check(named, "match.finished still fires its named callback")
	check(not generic, "a named event does not also fire match_event")
end

-- A world script cannot reach match_event and vice versa.
do
	local rt = new_rt()
	local wrong = false
	rt:on("world_event", function() wrong = true end)
	rt:_handle_message('{"type":"match.players_total","payload":{"value":1}}')
	check(not wrong, "a match.* broadcast does not fire world_event")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all broadcast-event checks passed")
