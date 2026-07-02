-- Pure-Lua unit test for the SDK's entity-sync layer.
-- Run: cd asobi-defold && lua tests/test_entity_sync.lua
--
-- The test mocks Defold's `websocket` / `json` / `http` so the
-- realtime module can be loaded outside the engine, and exercises
-- only the partial-diff merge + dispatch logic.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

-- Defold stubs the realtime module references at module scope.
websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
json = {encode = function() return "" end, decode = function() return {} end}
http = {request = function() end}
hash = function(s) return s end

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

-- ------------------------------------------------------------------
-- Test 1: op="a" populates the entity with full state and fires added.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local seen
	rt:on("entity_added", function(id, state) seen = {id = id, state = state} end)
	rt:_dispatch_tick({tick = 1, updates = {{op = "a", id = "p1", x = 10, y = 20, type = "player"}}})

	check(seen ~= nil, "entity_added callback fired on op='a'")
	check(seen.id == "p1", "entity_added id matches")
	check(seen.state.x == 10 and seen.state.y == 20 and seen.state.type == "player",
		"entity_added carries full state")
	check(rt.entities["p1"].x == 10, "registry has full state after add")
end

-- ------------------------------------------------------------------
-- Test 2: op="u" with only x preserves y from prior state (the bug
-- that broke barrow_defold ghosts when peer_manager defaulted y to 0).
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {{op = "a", id = "p1", x = 10, y = 20, type = "player"}}})
	local seen
	rt:on("entity_updated", function(id, state, changed) seen = {id = id, state = state, changed = changed} end)
	rt:_dispatch_tick({tick = 2, updates = {{op = "u", id = "p1", x = 50}}})

	check(seen ~= nil, "entity_updated callback fired")
	check(seen.state.x == 50, "x updated to new value")
	check(seen.state.y == 20, "y PRESERVED from prior state (no teleport to 0)")
	check(seen.state.type == "player", "type preserved")
	check(#seen.changed == 1 and seen.changed[1] == "x", "changed list contains only x")
end

-- ------------------------------------------------------------------
-- Test 3: op="u" with no actual change is a no-op (no callback).
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {{op = "a", id = "p1", x = 10, y = 20}}})
	local fired = false
	rt:on("entity_updated", function() fired = true end)
	rt:_dispatch_tick({tick = 2, updates = {{op = "u", id = "p1", x = 10}}})
	check(not fired, "entity_updated does NOT fire when value is unchanged")
end

-- ------------------------------------------------------------------
-- Test 4: op="r" removes entity and fires entity_removed.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {{op = "a", id = "p1", x = 10, y = 20}}})
	local removed_id
	rt:on("entity_removed", function(id) removed_id = id end)
	rt:_dispatch_tick({tick = 2, updates = {{op = "r", id = "p1"}}})
	check(removed_id == "p1", "entity_removed callback fires with id")
	check(rt.entities["p1"] == nil, "entity gone from registry")
end

-- ------------------------------------------------------------------
-- Test 5: on_tick fires once per dispatch with tick number.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local tick_seen
	rt:on("tick", function(tick) tick_seen = tick end)
	rt:_dispatch_tick({tick = 42, updates = {{op = "a", id = "p1", x = 1, y = 2}}})
	check(tick_seen == 42, "on_tick fires with tick number")
end

-- ------------------------------------------------------------------
-- Test 6: multiple updates in one tick all get merged.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local fired = 0
	rt:on("entity_added", function() fired = fired + 1 end)
	rt:_dispatch_tick({tick = 1, updates = {
		{op = "a", id = "p1", x = 1, y = 2},
		{op = "a", id = "p2", x = 3, y = 4},
		{op = "a", id = "p3", x = 5, y = 6},
	}})
	check(fired == 3, "added fires once per new entity in batch")
	check(rt.entities["p1"].x == 1 and rt.entities["p2"].x == 3 and rt.entities["p3"].x == 5,
		"all entities present in registry")
end

-- ------------------------------------------------------------------
-- Test 7: two realtime instances have independent state (no cross-talk).
-- This is the regression test for asobi-defold issue #17.
-- ------------------------------------------------------------------
do
	local rt_a = new_rt()
	local rt_b = new_rt()
	local seen_a, seen_b = 0, 0
	rt_a:on("entity_added", function() seen_a = seen_a + 1 end)
	rt_b:on("entity_added", function() seen_b = seen_b + 1 end)
	rt_a:_dispatch_tick({tick = 1, updates = {{op = "a", id = "pa", x = 1, y = 1}}})
	check(seen_a == 1 and seen_b == 0, "rt_a tick does not leak into rt_b")
	rt_b:_dispatch_tick({tick = 1, updates = {
		{op = "a", id = "pb1", x = 2, y = 2},
		{op = "a", id = "pb2", x = 3, y = 3},
	}})
	check(seen_a == 1, "rt_a callback count unaffected by rt_b dispatch")
	check(seen_b == 2, "rt_b sees its own two entity_added")
	check(rt_a.entities["pa"] ~= nil and rt_a.entities["pb1"] == nil,
		"rt_a registry isolated from rt_b")
	check(rt_b.entities["pb1"] ~= nil and rt_b.entities["pa"] == nil,
		"rt_b registry isolated from rt_a")
end

-- ------------------------------------------------------------------
if failures == 0 then
	print("OK: all entity-sync tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end
