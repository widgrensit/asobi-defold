-- Smoke test for asobi-defold against widgrensit/sdk_demo_backend.
--
-- This file is Defold-engine-specific (uses `http.request`, `websocket`
-- via the asobi SDK). It is driven by smoke_tests/headless/main.script
-- inside a Defold project; see smoke_tests/README.md.
--
-- SCOPE: single-client subset of the canonical SMOKE.md flow.
--
-- The SDK's `asobi.realtime` module currently uses module-level state
-- (a single `_connection`, `_client`, `_callbacks` table), so two
-- distinct clients cannot coexist in the same Lua VM. The full 2-player
-- matchmaker → match.matched → match.input → match.state flow therefore
-- can't be exercised here without first refactoring realtime.lua to be
-- per-instance. Once that lands, expand this back to the full flow.
--
-- Until then this smoke validates:
--   1. HTTP /api/v1/auth/register works (Scenario 1, step 1).
--   2. WebSocket /ws connects and authenticates (Scenario 1, steps 2-3).
--   3. session.connected event fires with a player_id.
--   4. matchmaker.add → matchmaker.queued round-trip (proves outbound
--      WS messages reach the server and inbound dispatch works).

local asobi = require("asobi.client")

local M = {}

local QUEUE_TIMEOUT = 10.0

local state = nil

local function log(msg)
	print("[smoke] " .. tostring(msg))
end

local function fail(msg)
	print("[smoke] FAIL: " .. tostring(msg))
	state.done = true
	state.ok = false
end

local function pass()
	log("PASS (single-client subset)")
	state.done = true
	state.ok = true
end

--- Entry point. Call from a Defold main.script on_init.
---
--- Passes `done_callback(ok)` when the test finishes (either pass or
--- fail); `ok` is true on pass.
function M.run(host, port, done_callback)
	state = {
		client = nil,
		connected = false,
		queued = false,
		done = false,
		ok = false,
		started_at = socket.gettime(),
		done_callback = done_callback,
	}

	state.client = asobi.create(host, port)

	local username = "smoke_def_" .. tostring(os.time()) .. "_" .. tostring(math.random(1e6))
	log("Registering " .. username)
	state.client.auth.register(state.client, username, "smoke_pw_12345", username, function(data, err)
		if err then
			fail("register failed: " .. tostring(err.error or err))
			return
		end
		log("Registered: player_id=" .. tostring(data.player_id))
		M._connect()
	end)
end

function M._connect()
	state.client.realtime.on("connected", function(payload)
		state.connected = true
		log("session.connected, player_id=" .. tostring(payload.player_id))
		state.client.realtime.add_to_matchmaker({ mode = "demo" })
		log("Sent matchmaker.add (mode=demo)")
	end)

	state.client.realtime.on("matchmaker_queued", function(payload)
		state.queued = true
		log("matchmaker.queued, ticket_id=" .. tostring(payload and payload.ticket_id))
		pass()
	end)

	state.client.realtime.on("error", function(payload)
		fail("server error: " .. tostring(payload and payload.reason))
	end)

	state.client.realtime.connect()
end

--- Call from main.script on_update to enforce timeouts and fire the
--- done_callback once the run resolves.
function M.update()
	if state == nil then return end
	if not state.done then
		local elapsed = socket.gettime() - state.started_at
		if elapsed > QUEUE_TIMEOUT then
			if not state.connected then
				fail("timeout waiting for session.connected")
			elseif not state.queued then
				fail("timeout waiting for matchmaker.queued")
			end
		end
	end
	if state.done and state.done_callback then
		local cb = state.done_callback
		state.done_callback = nil
		cb(state.ok)
	end
end

return M
