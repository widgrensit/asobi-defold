-- Unit test for find_or_create_match.
--
-- Pure Lua 5.4, no network or Defold engine. The match twin of
-- find_or_create_world, so it must send match.find_or_create with `mode` as the
-- only payload field, take join_match's optional `{ctx = ...}` table, and
-- resolve its callback off a match.joined reply.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

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

-- mode is the whole payload: no match_size, no properties, nothing invented
do
	local rt, sent = new_rt()
	rt:find_or_create_match("arena")
	check(#sent == 1 and sent[1].mtype == "match.find_or_create",
		"find_or_create_match sends match.find_or_create")
	check(sent[1] and sent[1].payload.mode == "arena", "find_or_create_match passes the mode")
	check(sent[1] and sent[1].payload.ctx == nil, "find_or_create_match omits ctx when none given")
	local keys = 0
	for _ in pairs(sent[1].payload) do keys = keys + 1 end
	check(keys == 1, "the payload carries mode and nothing else")
end

-- find_or_create_match(mode, callback): callback in the second slot
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:find_or_create_match("arena", cb)
	check(sent[1] and sent[1].cb == cb, "find_or_create_match takes a callback as arg 2")
	check(sent[1] and sent[1].payload.ctx == nil,
		"find_or_create_match with a bare callback sends no ctx")
end

-- find_or_create_match(mode, {ctx = ...}, callback): the same join context
-- join_match accepts, forwarded untouched
do
	local rt, sent = new_rt()
	local cb = function() end
	rt:find_or_create_match("arena", {ctx = {code = "AB12"}}, cb)
	check(sent[1] and sent[1].payload.ctx and sent[1].payload.ctx.code == "AB12",
		"find_or_create_match forwards ctx")
	check(sent[1] and sent[1].cb == cb, "find_or_create_match forwards the callback past opts")
end

-- The reply is match.joined, routed exactly as match.join's is
do
	local rt = realtime.new({})
	rt.connection = {}
	local got, err_got = nil, nil
	rt:find_or_create_match("arena", function(payload, err) got, err_got = payload, err end)
	local cid = encoded[#encoded].cid
	check(cid ~= nil, "find_or_create_match sends a cid")
	rt:_handle_message(('{"type":"match.joined","cid":"%s","payload":{"match_id":"m-1","player_count":1}}')
		:format(cid))
	check(got and got.match_id == "m-1" and got.player_count == 1,
		"match.joined resolves the find_or_create_match callback")
	check(err_got == nil, "a successful find-or-create reports no error")
end

-- A mode that has not set quick_play is refused on the same callback
do
	local rt = realtime.new({})
	rt.connection = {}
	local got, err_got = nil, nil
	rt:find_or_create_match("ranked", function(payload, err) got, err_got = payload, err end)
	local cid = encoded[#encoded].cid
	rt:_handle_message(('{"type":"error","cid":"%s","payload":{"reason":"quick_play_disabled"}}')
		:format(cid))
	check(got == nil and err_got == "quick_play_disabled",
		"a mode without quick_play reports quick_play_disabled")
end

-- Disconnected: the callback still fires rather than being dropped silently
do
	local rt = realtime.new({})
	local err_got = nil
	rt:find_or_create_match("arena", function(_payload, err) err_got = err end)
	check(err_got == "not connected", "find_or_create_match reports not connected")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
