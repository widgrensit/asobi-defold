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

-- Delta helpers mirror the BINARY wire shape (0x02 entity_delta):
--   {op = "add"|"update"|"remove", entity_id = <id>, fields = {...}}
local function add(id, fields) return {op = "add", entity_id = id, fields = fields} end
local function update(id, fields) return {op = "update", entity_id = id, fields = fields} end
local function remove(id) return {op = "remove", entity_id = id} end

-- ...and these mirror the JSON shape the server actually sends on world.tick
-- and match.state (asobi_zone.erl): short op, `id`, game fields at the TOP
-- level rather than nested under `fields`.
--
-- Every test below used the binary helpers only, which is why the SDK could
-- ignore the JSON shape entirely - dropping every entity update in any game
-- not on the binary protocol - while this suite stayed green.
local function jadd(id, fields)
	local d = {op = "a", id = id}
	for k, v in pairs(fields or {}) do d[k] = v end
	return d
end
local function jupdate(id, fields)
	local d = {op = "u", id = id}
	for k, v in pairs(fields or {}) do d[k] = v end
	return d
end
local function jremove(id) return {op = "r", id = id} end

-- ------------------------------------------------------------------
-- Test 1: op="add" populates the entity with full state and fires added.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local seen
	rt:on("entity_added", function(id, state) seen = {id = id, state = state} end)
	rt:_dispatch_tick({tick = 1, updates = {add("p1", {x = 10, y = 20, type = "player"})}})

	check(seen ~= nil, "entity_added callback fired on op='add'")
	check(seen.id == "p1", "entity_added id matches")
	check(seen.state.x == 10 and seen.state.y == 20 and seen.state.type == "player",
		"entity_added carries full state")
	check(rt.entities["p1"].x == 10, "registry has full state after add")
end

-- ------------------------------------------------------------------
-- Test 2: op="update" with only x preserves y from prior state (the bug
-- that broke barrow_defold ghosts when peer_manager defaulted y to 0).
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {add("p1", {x = 10, y = 20, type = "player"})}})
	local seen
	rt:on("entity_updated", function(id, state, changed) seen = {id = id, state = state, changed = changed} end)
	rt:_dispatch_tick({tick = 2, updates = {update("p1", {x = 50})}})

	check(seen ~= nil, "entity_updated callback fired")
	check(seen.state.x == 50, "x updated to new value")
	check(seen.state.y == 20, "y PRESERVED from prior state (no teleport to 0)")
	check(seen.state.type == "player", "type preserved")
	check(#seen.changed == 1 and seen.changed[1] == "x", "changed list contains only x")
end

-- ------------------------------------------------------------------
-- Test 3: op="update" with no actual change is a no-op (no callback).
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {add("p1", {x = 10, y = 20})}})
	local fired = false
	rt:on("entity_updated", function() fired = true end)
	rt:_dispatch_tick({tick = 2, updates = {update("p1", {x = 10})}})
	check(not fired, "entity_updated does NOT fire when value is unchanged")
end

-- ------------------------------------------------------------------
-- Test 4: op="remove" removes entity and fires entity_removed.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	rt:_dispatch_tick({tick = 1, updates = {add("p1", {x = 10, y = 20})}})
	local removed_id
	rt:on("entity_removed", function(id) removed_id = id end)
	rt:_dispatch_tick({tick = 2, updates = {remove("p1")}})
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
	rt:_dispatch_tick({tick = 42, updates = {add("p1", {x = 1, y = 2})}})
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
		add("p1", {x = 1, y = 2}),
		add("p2", {x = 3, y = 4}),
		add("p3", {x = 5, y = 6}),
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
	rt_a:_dispatch_tick({tick = 1, updates = {add("pa", {x = 1, y = 1})}})
	check(seen_a == 1 and seen_b == 0, "rt_a tick does not leak into rt_b")
	rt_b:_dispatch_tick({tick = 1, updates = {
		add("pb1", {x = 2, y = 2}),
		add("pb2", {x = 3, y = 3}),
	}})
	check(seen_a == 1, "rt_a callback count unaffected by rt_b dispatch")
	check(seen_b == 2, "rt_b sees its own two entity_added")
	check(rt_a.entities["pa"] ~= nil and rt_a.entities["pb1"] == nil,
		"rt_a registry isolated from rt_b")
	check(rt_b.entities["pb1"] ~= nil and rt_b.entities["pa"] == nil,
		"rt_b registry isolated from rt_a")
end

-- ------------------------------------------------------------------
-- The JSON shape, end to end: add, partial update, remove.
-- ------------------------------------------------------------------
do
	local rt = new_rt()
	local added, updated, removed, changed_fields
	rt:on("entity_added", function(id, state) added = {id, state} end)
	rt:on("entity_updated", function(id, state, changed)
		updated = {id, state}
		changed_fields = changed
	end)
	rt:on("entity_removed", function(id) removed = id end)

	rt:_dispatch_tick({tick = 1, updates = {jadd("p1", {x = 10, y = 20, hp = 100})}})
	check(added ~= nil, "json add fires entity_added")
	check(rt.entities["p1"] ~= nil, "json add reaches the registry")
	check(rt.entities["p1"].x == 10 and rt.entities["p1"].hp == 100,
		"json add lifts top-level fields into state")
	check(rt.entities["p1"].op == nil and rt.entities["p1"].id == nil,
		"json add does not leak envelope keys into state")

	rt:_dispatch_tick({tick = 2, updates = {jupdate("p1", {x = 11})}})
	check(updated ~= nil, "json update fires entity_updated")
	check(rt.entities["p1"].x == 11, "json update applies the changed field")
	check(rt.entities["p1"].hp == 100, "json update MERGES, keeping untouched fields")
	check(#changed_fields == 1 and changed_fields[1] == "x",
		"json update reports only what changed")

	rt:_dispatch_tick({tick = 3, updates = {jremove("p1")}})
	check(removed == "p1", "json remove fires entity_removed")
	check(rt.entities["p1"] == nil, "json remove clears the registry")
end

-- The fixture is the shared corpus - the exact bytes the server sends. Hand
-- written deltas agree with whatever the SDK already believes; this one does
-- not, which is the whole point of checking against it.
do
	local f = io.open("tests/fixtures/world.tick.json", "r")
	check(f ~= nil, "world.tick.json fixture is readable")
	if f then
		local raw = f:read("*a")
		f:close()
		local decode = dofile("tests/json_decode.lua")
		local msg = decode(raw)
		local rt = new_rt()
		local added
		rt:on("entity_added", function(id, state) added = {id = id, state = state} end)
		rt:_dispatch_tick(msg.payload)
		check(added ~= nil, "the world.tick fixture produces an entity_added")
		if added then
			check(added.state.x == 120 and added.state.y == 80,
				"the world.tick fixture's coordinates reach the callback")
		end
	end
end

-- ------------------------------------------------------------------
if failures == 0 then
	print("OK: all entity-sync tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end
