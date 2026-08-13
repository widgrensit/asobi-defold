-- module.event: a named push from an extension, {module, event, data}. The
-- SDK surfaces it on the module_event callback with the whole payload; the app
-- reads payload.event and payload.data to route. The inner event name is data,
-- never a dispatch gate, so an unfamiliar one still surfaces. Also covers the
-- multi-handler contract: two on() for the same event both fire, in order.
--
-- Pure Lua 5.4, no network or Defold engine.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end
_G.json = {decode = dofile("tests/json_decode.lua"), encode = function() return "<encoded>" end}

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

-- The canonical fixture surfaces on module_event with module/event/data intact.
do
	local rt = realtime.new({})
	local payload
	rt:on("module_event", function(p) payload = p end)
	rt:_handle_message(read_file("tests/fixtures/module.event.json"))
	check(payload ~= nil, "module.event fires on(module_event)")
	check(payload and payload.module == "quests", "payload carries the module name")
	check(payload and payload.event == "quests.completed", "payload carries the inner event name")
	check(payload and payload.data and payload.data.reward == 250, "payload carries the data object")
end

-- The inner event name is data, not a dispatch gate: an unfamiliar one still
-- surfaces on module_event rather than being dropped. This is the conformance
-- behaviour the 1.0 wire freeze needs.
do
	local rt = realtime.new({})
	local payload
	rt:on("module_event", function(p) payload = p end)
	rt:_handle_message(
		'{"type":"module.event","payload":{"module":"mystery","event":"mystery.happened","data":{"x":1}}}')
	check(payload ~= nil, "an unfamiliar inner event still fires module_event")
	check(payload and payload.event == "mystery.happened", "the unfamiliar event name reaches the app as data")
end

-- Two handlers for one event both fire, in registration order.
do
	local rt = realtime.new({})
	local order = {}
	rt:on("module_event", function() order[#order + 1] = "first" end)
	rt:on("module_event", function() order[#order + 1] = "second" end)
	rt:_handle_message(read_file("tests/fixtures/module.event.json"))
	check(#order == 2, "both handlers fire")
	check(order[1] == "first" and order[2] == "second", "handlers fire in registration order")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
