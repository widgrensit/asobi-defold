-- Unit test for asobi.quick_start: the one-call guest -> connect -> queue
-- helper. Pure Lua 5.4, no network or Defold engine. Stubs the websocket
-- global and the guest_device auth call, then asserts quick_start wires the
-- handlers in the right order (register-before-connect) and queues on connect.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

local auth = require("asobi.api.auth")
local asobi = require("asobi.client")

local failures = 0
local function check(cond, msg)
	if cond then
		print("ok - " .. msg)
	else
		failures = failures + 1
		print("NOT OK - " .. msg)
	end
end

-- Drive guest sign-in deterministically: success unless told to fail.
local function stub_guest(result_err)
	auth.guest_device = function(client, cb)
		if result_err then
			cb(nil, result_err)
		else
			client.set_tokens("access-xyz", "refresh-xyz")
			cb({player_id = "p1"}, nil)
		end
	end
end

-- happy path: ssl default -> wss://host/ws (443 dropped), queues the mode on connect
do
	stub_guest(nil)
	local client = asobi.quick_start({host = "h.example", mode = "arena"})
	check(client and client.ws_url == "wss://h.example/ws", "quick_start builds a wss url with default ssl")
	check(client.base_url == "https://h.example", "quick_start builds an https base url")

	local rt = client.realtime
	check(rt.callbacks["matchmaker_queued"] == nil, "no on_queued -> no matchmaker_queued handler")
	check(type(rt.callbacks["connected"][1]) == "function", "registers a connected handler before connect")

	-- capture the queue send, then simulate the server confirming the session
	local sent = {}
	rt._send = function(_self, mtype, payload) sent[#sent + 1] = {mtype = mtype, payload = payload} end
	rt.callbacks["connected"][1]()
	check(#sent == 1 and sent[1].mtype == "matchmaker.add", "queues via matchmaker.add on connect")
	check(sent[1] and sent[1].payload.mode == "arena", "queues the requested mode")
end

-- callbacks wired: on_queued / on_matched / on_failed registered on success
do
	stub_guest(nil)
	local failed
	local client = asobi.quick_start({
		host = "h.example",
		on_queued = function() end,
		on_matched = function() end,
		on_failed = function(p) failed = p end,
	})
	local rt = client.realtime
	check(type(rt.callbacks["matchmaker_queued"][1]) == "function", "on_queued -> matchmaker_queued handler")
	check(type(rt.callbacks["match_matched"][1]) == "function", "on_matched -> match_matched handler")
	check(type(rt.callbacks["matchmaker_failed"][1]) == "function", "on_failed -> matchmaker_failed handler")
	check(type(rt.callbacks["error"][1]) == "function", "on_failed also covers error")

	-- a transport error routes through the error handler to on_failed with a reason
	rt.callbacks["error"][1]({error = "socket boom"})
	check(failed and failed.reason == "socket boom", "error event maps to on_failed reason")
end

-- ssl=false uses the plain ws url + default plain port
do
	stub_guest(nil)
	local client = asobi.quick_start({host = "localhost", ssl = false})
	check(client.ws_url == "ws://localhost:8084/ws", "ssl=false builds a plain ws url on 8084")
end

-- guest failure routes to on_failed with the error reason
do
	stub_guest({error = "boom"})
	local got
	asobi.quick_start({host = "h.example", on_failed = function(p) got = p.reason end})
	check(got == "boom", "guest sign-in failure calls on_failed with the reason")
end

-- host is required
do
	local ok = pcall(function() asobi.quick_start({}) end)
	check(not ok, "missing host raises")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
