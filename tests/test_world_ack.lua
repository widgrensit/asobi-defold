-- world.ack: asobi core's client-side-prediction ack {tick, seq}. Two halves:
--   inbound  - a world.ack frame dispatches on the typed world_ack callback. It
--              is a named entry, so it does NOT fall through to the generic
--              world.* catch-all as world_event "ack".
--   outbound - send_world_input(input, seq) rides an optional numeric seq as a
--              top-level sibling of payload ({type, seq, payload}), stamped only
--              when given so pre-prediction callers are unaffected.
--
-- Pure Lua 5.4, no network or Defold engine.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

-- encode hands back the table (as tests/test_join.lua does) so the outbound
-- assertions can read the frame the SDK built.
local encoded = {}
_G.json = {
	decode = dofile("tests/json_decode.lua"),
	encode = function(t) encoded[#encoded + 1] = t; return "<encoded>" end,
}

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

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

-- Inbound: the canonical fixture dispatches on world_ack with tick/seq intact.
do
	local rt = realtime.new({})
	local payload
	rt:on("world_ack", function(p) payload = p end)
	rt:_handle_message(read_file("tests/fixtures/world.ack.json"))
	check(payload ~= nil, "world.ack fires on(world_ack)")
	check(payload and payload.tick == 42, "payload carries the tick")
	check(payload and payload.seq == 412, "payload carries the acked seq")
end

-- Inbound: world.ack is a named entry, so it does NOT also leak onto the
-- generic world_event catch-all as name "ack".
do
	local rt = realtime.new({})
	local world_event_name
	rt:on("world_ack", function() end)
	rt:on("world_event", function(name) world_event_name = name end)
	rt:_handle_message(read_file("tests/fixtures/world.ack.json"))
	check(world_event_name == nil, "world.ack does not fall through to the world_event catch-all")
end

-- Outbound: send_world_input(input, seq) stamps a numeric top-level seq.
do
	local rt = realtime.new({})
	rt.connection = {}
	local input = {kind = "move", x = 500, y = 200}
	rt:send_world_input(input, 7)
	local frame = encoded[#encoded]
	check(frame and frame.type == "world.input", "send_world_input sends world.input")
	check(frame and frame.payload == input, "the input rides in payload")
	check(frame and frame.seq == 7, "seq rides as a top-level sibling of payload")
	check(frame and type(frame.seq) == "number", "seq is kept numeric")
end

-- Outbound: with no seq the frame carries none, so json.encode drops the key and
-- nothing extra reaches the wire.
do
	local rt = realtime.new({})
	rt.connection = {}
	rt:send_world_input({kind = "move"})
	local frame = encoded[#encoded]
	check(frame and frame.type == "world.input", "send_world_input still sends without a seq")
	check(frame and frame.seq == nil, "no seq stamped when none given")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
