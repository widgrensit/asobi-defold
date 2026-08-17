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
-- Interest-ring zone safety. A player is subscribed to several zones at once,
-- each an independent server process, so frames from two of them have no order
-- relative to each other. These are the cases that used to corrupt the table.
-- ------------------------------------------------------------------

local function jadd(id, fields)
	local d = {op = "a", id = id}
	if fields then for k, v in pairs(fields) do d[k] = v end end
	return d
end
local function jremove(id) return {op = "r", id = id} end

-- Captures frames the SDK sends, so the resync request is observable.
local function capturing_rt()
	local rt = new_rt()
	rt.connection = {}
	rt.sent = {}
	local encode = json.encode
	json.encode = function(frame) rt.sent[#rt.sent + 1] = frame; return "" end
	rt._restore_json = function() json.encode = encode end
	return rt
end

-- The crossing, in the order that used to lose the entity: the new zone claims
-- it, then the old zone's removal arrives late.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {jadd("p1", {x = 5})}})
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {jremove("p1")}})
	check(rt.entities.p1 ~= nil, "a late remove from the zone left must not delete a crossed entity")
	check(rt.entity_zone.p1 == "1:1", "the entity stays owned by the zone that claimed it")
end

-- The same crossing in the other order, which always worked, to prove the fix
-- did not simply invert the bug.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {jremove("p1")}})
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {jadd("p1", {x = 5})}})
	check(rt.entities.p1 ~= nil, "remove-then-add converges on the entity being present")
	check(rt.entity_zone.p1 == "1:1", "and owned by the zone that added it")
end

-- A stale update from the zone that no longer owns the entity is ignored too,
-- or a crossing player would snap back to their old zone's last position.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {jadd("p1", {x = 100})}})
	rt:_dispatch_tick({zone = {0, 1}, frame_seq = 1, tick = 1, updates = {{op = "u", id = "p1", x = 7}}})
	check(rt.entities.p1.x == 100, "a stale update from the previous zone is ignored")
end

-- A remove from the owning zone still works. The guard must not make entities
-- immortal.
do
	local rt = new_rt()
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 1, tick = 1, updates = {jadd("p1", {x = 5})}})
	rt:_dispatch_tick({zone = {1, 1}, frame_seq = 2, tick = 2, updates = {jremove("p1")}})
	check(rt.entities.p1 == nil, "the owning zone can still remove its own entity")
	check(rt.entity_zone.p1 == nil, "and ownership is released with it")
end

-- ------------------------------------------------------------------
-- Gap detection and repair.
-- ------------------------------------------------------------------

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 1, tick = 1, updates = {jadd("e1")}})
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 4, tick = 4, updates = {jadd("e2")}})
	check(#rt.sent == 1, "a sequence gap asks for exactly one resync")
	check(rt.sent[1] and rt.sent[1].type == "world.resync", "the request is world.resync")
	check(rt.sent[1].payload.zone[1] == 2 and rt.sent[1].payload.zone[2] == 0,
		"and it names the zone that gapped, not the whole ring")
	check(rt.entities.e2 ~= nil, "the gapping frame is still applied - it is the newest news")
	-- A client that keeps gapping asks once per incident, not once per frame.
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 9, tick = 9, updates = {jadd("e3")}})
	check(#rt.sent == 1, "a second gap while a resync is outstanding does not re-ask")
	rt._restore_json()
end

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 5, tick = 5, updates = {jadd("e1")}})
	rt:_dispatch_tick({zone = {2, 0}, frame_seq = 5, tick = 5, updates = {{op = "u", id = "e1", x = 9}}})
	check(rt.entities.e1.x == nil, "a repeated frame_seq is dropped rather than re-applied")
	check(#rt.sent == 0, "and a duplicate is not mistaken for a gap")
	rt._restore_json()
end

-- A gap in one zone says nothing about another. Sequences are per zone.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {0, 0}, frame_seq = 1, tick = 1, updates = {jadd("a1")}})
	rt:_dispatch_tick({zone = {1, 0}, frame_seq = 1, tick = 1, updates = {jadd("b1")}})
	rt:_dispatch_tick({zone = {1, 0}, frame_seq = 2, tick = 2, updates = {jadd("b2")}})
	check(#rt.sent == 0, "contiguous sequences in two zones are not a gap in either")
	rt._restore_json()
end

-- ------------------------------------------------------------------
-- Keyframe adoption.
-- ------------------------------------------------------------------

do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {3, 3}, frame_seq = 7, tick = 7, updates = {jadd("keep"), jadd("drop")}})
	rt:_dispatch_tick({zone = {9, 9}, frame_seq = 1, tick = 1, updates = {jadd("other")}})
	-- The keyframe is this zone's whole state: `drop` is gone, `keep` remains,
	-- and another zone's entity is untouched.
	rt:_dispatch_tick({zone = {3, 3}, frame_seq = 2, kf = true, tick = 0, updates = {jadd("keep")}})
	check(rt.entities.keep ~= nil, "a keyframe keeps what it lists")
	check(rt.entities.drop == nil, "a keyframe removes what it omits, for its own zone")
	check(rt.entities.other ~= nil, "and leaves another zone's entities alone")
	check(rt.zone_seq["3:3"] == 2, "a keyframe resets the sequence even when it moves backwards")
	rt._restore_json()
end

-- The keyframe must be adopted even though its frame_seq is lower than what the
-- client has already seen, because a zone restart resets the counter while the
-- zone's identity is unchanged. A monotonic guard here freezes the client on
-- pre-crash state forever.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {4, 4}, frame_seq = 500, tick = 500, updates = {jadd("stale")}})
	rt:_dispatch_tick({zone = {4, 4}, frame_seq = 1, kf = true, tick = 0, updates = {jadd("fresh")}})
	check(rt.entities.fresh ~= nil, "a post-restart keyframe is adopted despite a lower frame_seq")
	check(rt.entities.stale == nil, "and clears the pre-restart state it replaces")
	rt._restore_json()
end

-- A keyframe clears the outstanding-resync flag, so the next real gap can ask.
do
	local rt = capturing_rt()
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 1, tick = 1, updates = {jadd("e1")}})
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 5, tick = 5, updates = {jadd("e2")}})
	check(#rt.sent == 1, "first gap asks")
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 5, kf = true, tick = 0, updates = {jadd("e1")}})
	rt:_dispatch_tick({zone = {5, 5}, frame_seq = 20, tick = 20, updates = {jadd("e9")}})
	check(#rt.sent == 2, "after the keyframe lands, a later gap asks again")
	rt._restore_json()
end

-- ------------------------------------------------------------------
-- match.state carries no zone, and must behave exactly as it did before.
-- ------------------------------------------------------------------

do
	local rt = capturing_rt()
	rt:_dispatch_tick({tick = 1, updates = {jadd("m1", {x = 1})}})
	rt:_dispatch_tick({tick = 2, updates = {{op = "u", id = "m1", x = 2}}})
	rt:_dispatch_tick({tick = 3, updates = {jremove("m1")}})
	check(rt.entities.m1 == nil, "match mode still adds, updates and removes in one namespace")
	check(#rt.sent == 0, "and never asks for a resync, having no zone to name")
	rt._restore_json()
end

-- ------------------------------------------------------------------
if failures == 0 then
	print("OK: all entity-sync tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end
