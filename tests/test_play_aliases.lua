-- Unit test for the convenience aliases quick_play / join_or_host.
--
-- Pure Lua 5.4, no network or Defold engine. Asserts each alias emits exactly
-- the same message as the primitive it wraps, so the sugar can never drift from
-- add_to_matchmaker / find_or_create_world.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

local realtime = require("asobi.realtime")

local failures = 0
local function check(cond, msg)
	if cond then
		print("ok - " .. msg)
	else
		failures = failures + 1
		print("NOT OK - " .. msg)
	end
end

-- A realtime instance whose sends are captured instead of hitting a socket.
local function new_rt()
	local rt = realtime.new({})
	local sent = {}
	rt._send = function(_self, mtype, payload)
		sent[#sent + 1] = {mtype = mtype, payload = payload}
	end
	rt._send_with_callback = function(_self, mtype, payload, cb)
		sent[#sent + 1] = {mtype = mtype, payload = payload, cb = cb}
	end
	return rt, sent
end

-- quick_play(mode) is add_to_matchmaker: matchmaker.add {mode = mode}
do
	local rt, sent = new_rt()
	rt:quick_play("arena")
	check(#sent == 1 and sent[1].mtype == "matchmaker.add", "quick_play sends matchmaker.add")
	check(sent[1] and sent[1].payload.mode == "arena", "quick_play passes the mode")
end

-- quick_play forwards a full opts table (mode + properties), like add_to_matchmaker
do
	local rt, sent = new_rt()
	rt:quick_play({mode = "arena", properties = {skill = 1200}})
	check(sent[1] and sent[1].payload.mode == "arena"
		and sent[1].payload.properties and sent[1].payload.properties.skill == 1200,
		"quick_play forwards an opts table")
end

-- join_or_host(mode, cb) is find_or_create_world: world.find_or_create {mode}, cb
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:join_or_host("town", cb)
	check(#sent == 1 and sent[1].mtype == "world.find_or_create", "join_or_host sends world.find_or_create")
	check(sent[1] and sent[1].payload.mode == "town", "join_or_host passes the mode")
	check(sent[1] and sent[1].cb == cb, "join_or_host forwards the callback")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
