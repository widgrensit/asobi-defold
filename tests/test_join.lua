-- Unit test for join_match / join_world.
--
-- Pure Lua 5.4, no network or Defold engine. Both take an optional opts table
-- carrying `ctx` and an optional callback, and both must stay callable in the
-- older `join(id, callback)` shape that shipped before opts existed.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

-- Same stub shape as tests/test_rpc.lua: encode hands back the table so a test
-- can read the cid the SDK chose rather than guessing one.
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

-- join_match(id) sends match.join and nothing else
do
	local rt, sent = new_rt()
	rt:join_match("m-1")
	check(#sent == 1 and sent[1].mtype == "match.join", "join_match sends match.join")
	check(sent[1] and sent[1].payload.match_id == "m-1", "join_match passes the match_id")
	check(sent[1] and sent[1].payload.ctx == nil, "join_match omits ctx when none given")
end

-- join_match(id, callback): callback in the second slot, the pre-opts shape
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:join_match("m-1", cb)
	check(sent[1] and sent[1].cb == cb, "join_match takes a callback as arg 2")
	check(sent[1] and sent[1].payload.ctx == nil, "join_match with a bare callback sends no ctx")
end

-- join_match(id, {ctx = ...}, callback): ctx reaches the wire untouched
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:join_match("m-1", {ctx = {code = "AB12"}}, cb)
	check(sent[1] and sent[1].payload.ctx and sent[1].payload.ctx.code == "AB12",
		"join_match forwards ctx")
	check(sent[1] and sent[1].cb == cb, "join_match forwards the callback past opts")
end

-- The reply is correlated by cid, so a callback resolves off match.joined
do
	local rt = realtime.new({})
	rt.connection = {}
	local got, err_got = nil, nil
	rt:join_match("m-1", function(payload, err) got, err_got = payload, err end)
	local cid = encoded[#encoded].cid
	check(cid ~= nil, "join_match sends a cid")
	rt:_handle_message(('{"type":"match.joined","cid":"%s","payload":{"match_id":"m-1","player_count":2}}')
		:format(cid))
	check(got and got.match_id == "m-1" and got.player_count == 2,
		"match.joined resolves the join_match callback")
	check(err_got == nil, "a successful join reports no error")
end

-- A refused join resolves the same callback with a reason
do
	local rt = realtime.new({})
	rt.connection = {}
	local got, err_got = nil, nil
	rt:join_match("m-9", function(payload, err) got, err_got = payload, err end)
	local cid = encoded[#encoded].cid
	rt:_handle_message(('{"type":"error","cid":"%s","payload":{"reason":"match_full"}}'):format(cid))
	check(got == nil and err_got == "match_full", "a full match reports match_full")
end

-- Disconnected: the callback still fires rather than being dropped silently
do
	local rt = realtime.new({})
	local err_got = nil
	rt:join_match("m-1", function(_payload, err) err_got = err end)
	check(err_got == "not connected", "join_match reports not connected")
end

-- join_world keeps the same three shapes
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:join_world("w-1")
	rt:join_world("w-2", cb)
	rt:join_world("w-3", {ctx = {code = "AB12"}}, cb)
	check(sent[1].mtype == "world.join" and sent[1].payload.world_id == "w-1",
		"join_world sends world.join")
	check(sent[2].cb == cb and sent[2].payload.ctx == nil, "join_world takes a callback as arg 2")
	check(sent[3].payload.ctx and sent[3].payload.ctx.code == "AB12" and sent[3].cb == cb,
		"join_world forwards ctx and the callback")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
