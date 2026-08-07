-- The server emits both dialects of every extension frame: game.message plus
-- module.message, game.error plus module.error, same body, back to back. Both
-- map to one SDK callback, so without a dedupe every game.send is delivered
-- twice.
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

local function counting_rt(event)
	local rt = realtime.new({})
	local seen = {}
	rt:on(event, function(payload) seen[#seen + 1] = payload end)
	return rt, seen
end

local GAME_MSG = '{"type":"game.message","payload":{"message":{"echo":"up","count":1}}}'
local MODULE_MSG = '{"type":"module.message","payload":{"message":{"echo":"up","count":1}}}'
local GAME_ERR = '{"type":"game.error","payload":{"callback":"handle_input"}}'
local MODULE_ERR = '{"type":"module.error","payload":{"callback":"handle_input"}}'

-- A current server: legacy frame first, then the module twin. One callback.
do
	local rt, seen = counting_rt("game_message")
	rt:_handle_message(GAME_MSG)
	rt:_handle_message(MODULE_MSG)
	check(#seen == 1, "a game.message + module.message pair fires game_message once")
	check(seen[1] and seen[1].message.echo == "up", "the surviving frame carries the body")
end

-- Order-agnostic: module first, legacy second, still one callback.
do
	local rt, seen = counting_rt("game_message")
	rt:_handle_message(MODULE_MSG)
	rt:_handle_message(GAME_MSG)
	check(#seen == 1, "a module-first pair also fires game_message once")
end

-- Two game.sends in a row are two messages, not deduped into one.
do
	local rt, seen = counting_rt("game_message")
	rt:_handle_message(GAME_MSG)
	rt:_handle_message(MODULE_MSG)
	rt:_handle_message(GAME_MSG)
	rt:_handle_message(MODULE_MSG)
	check(#seen == 2, "two sends deliver two messages")
end

-- A pre-S6 server sends only game.*; the frame must not be swallowed.
do
	local rt, seen = counting_rt("game_message")
	rt:_handle_message(GAME_MSG)
	rt:_handle_message(GAME_MSG)
	check(#seen == 2, "a legacy-only server still delivers every message")
end

-- ws_legacy_game_frames = false sends only module.*; same.
do
	local rt, seen = counting_rt("game_message")
	rt:_handle_message(MODULE_MSG)
	rt:_handle_message(MODULE_MSG)
	check(#seen == 2, "a module-only server still delivers every message")
end

-- game.error / module.error dedupe on the same latch.
do
	local rt, seen = counting_rt("game_error")
	rt:_handle_message(GAME_ERR)
	rt:_handle_message(MODULE_ERR)
	check(#seen == 1, "a game.error + module.error pair fires game_error once")
	check(seen[1] and seen[1].callback == "handle_input", "the surviving error carries the body")
end

-- The latch is per connection, not global.
do
	local rt_a, seen_a = counting_rt("game_message")
	rt_a:_handle_message(GAME_MSG)
	local rt_b, seen_b = counting_rt("game_message")
	rt_b:_handle_message(MODULE_MSG)
	check(#seen_a == 1 and #seen_b == 1, "each connection latches independently")
end

-- Non-extension frames are untouched by the latch.
do
	local rt, seen = counting_rt("match_state")
	rt:_handle_message(GAME_MSG)
	rt:_handle_message('{"type":"match.state","payload":{"elapsed_ms":10}}')
	rt:_handle_message('{"type":"match.state","payload":{"elapsed_ms":20}}')
	check(#seen == 2, "the latch does not touch other frame types")
end

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all passed")
