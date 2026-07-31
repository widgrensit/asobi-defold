-- Guard test: `add_to_matchmaker({"grid2"})` (array-shaped table) must fail
-- loudly instead of silently queuing for the "default" mode. Lua's
-- `{"grid2"}` sets the numeric index [1], not a field named `mode`, so this
-- is an easy typo for the keyed `{mode = "grid2"}` shape. Also covers
-- list_matches / list_worlds, which take the same opts shape.
--
-- Pure unit test, plain Lua 5.4:
--   lua5.4 tests/test_matchmaker_mode_guard.lua

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
		print("  ok  " .. msg)
	else
		print("  FAIL " .. msg)
		failures = failures + 1
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

-- The footgun: a positional table with no `mode` field must error, not
-- silently queue for "default".
do
	local rt = new_rt()
	local ok, err = pcall(function()
		rt:add_to_matchmaker({"grid2"})
	end)
	check(not ok, "add_to_matchmaker({\"grid2\"}) errors instead of defaulting")
	check(
		ok == false and tostring(err):find("did you mean", 1, true) ~= nil,
		"the error explains the correct shape"
	)
end

do
	local rt = new_rt()
	local ok = pcall(function()
		rt:list_matches({"grid2"}, function() end)
	end)
	check(not ok, "list_matches({\"grid2\"}, cb) errors instead of dropping the mode")
end

do
	local rt = new_rt()
	local ok = pcall(function()
		rt:list_worlds({"grid2"}, function() end)
	end)
	check(not ok, "list_worlds({\"grid2\"}, cb) errors instead of dropping the mode")
end

-- Legitimate call shapes must keep working exactly as before.
do
	local rt, sent = new_rt()
	local ok = pcall(function()
		rt:add_to_matchmaker()
	end)
	check(ok, "add_to_matchmaker() with no opts still works")
	check(sent[1] and sent[1].payload.mode == "default", "add_to_matchmaker() still defaults to \"default\"")
end

do
	local rt, sent = new_rt()
	local ok = pcall(function()
		rt:add_to_matchmaker("grid2")
	end)
	check(ok, "add_to_matchmaker(\"grid2\") bare string still works")
	check(sent[1] and sent[1].payload.mode == "grid2", "bare string still sets the mode")
end

do
	local rt, sent = new_rt()
	local ok = pcall(function()
		rt:add_to_matchmaker({})
	end)
	check(ok, "add_to_matchmaker({}) still works")
	check(sent[1] and sent[1].payload.mode == "default", "add_to_matchmaker({}) still defaults to \"default\"")
end

do
	local rt, sent = new_rt()
	local ok = pcall(function()
		rt:add_to_matchmaker({mode = "grid2", properties = {skill = 1200}})
	end)
	check(ok, "add_to_matchmaker({mode = ..., properties = ...}) still works")
	check(
		sent[1] and sent[1].payload.mode == "grid2" and sent[1].payload.properties.skill == 1200,
		"the keyed table still forwards mode and properties"
	)
end

-- quick_play forwards straight to add_to_matchmaker, so the guard covers it too.
do
	local rt = new_rt()
	local ok = pcall(function()
		rt:quick_play({"grid2"})
	end)
	check(not ok, "quick_play({\"grid2\"}) errors via the same guard")
end

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all matchmaker mode-guard checks passed")
