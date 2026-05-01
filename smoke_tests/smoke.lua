-- Smoke test for asobi-defold against widgrensit/sdk_demo_backend.
--
-- This file is Defold-engine-specific (uses `http.request`,
-- `websocket` via the asobi SDK). Run it inside a minimal Defold
-- project; see smoke_tests/README.md for the setup.
--
-- Exercises the 3 canonical scenarios against sdk_demo_backend (see
-- widgrensit/sdk_demo_backend/SMOKE.md for the contract).

local asobi = require("asobi.client")
local realtime = require("asobi.realtime")

local M = {}

local MATCH_MODE = "demo"
local MATCH_TIMEOUT = 10.0
local STATE_TIMEOUT = 3.0
local X_DELTA = 10

local state = nil  -- per-player state, re-initialised in M.run

local function log(msg)
	print("[smoke] " .. tostring(msg))
end

local function fail(msg)
	print("[smoke] FAIL: " .. tostring(msg))
	state.done = true
	state.ok = false
end

local function pass()
	log("PASS")
	state.done = true
	state.ok = true
end

--- Entry point. Call from a Defold main.script on_init.
---
--- Passes `done_callback(ok)` when the test finishes (either pass
--- or fail); `ok` is true on pass.
function M.run(host, port, done_callback)
	state = {
		a = nil,
		b = nil,
		match_a = nil,
		match_b = nil,
		x_initial = nil,
		input_sent = false,
		done = false,
		ok = false,
		started_at = socket.gettime(),
		done_callback = done_callback,
	}

	-- Two independent clients.
	state.a = asobi.new({ host = host, port = port })
	state.b = asobi.new({ host = host, port = port })

	-- Register both, then wire up realtime.
	local registered = 0
	local on_reg = function(res, which)
		if res.error then
			fail("register failed: " .. tostring(res.error))
			return
		end
		log("Registered: " .. res.player_id)
		registered = registered + 1
		if registered == 2 then
			M._connect_and_queue()
		end
	end

	state.a.auth.register(
		"smoke_a_" .. tostring(math.random(1e9)),
		"smoke_pw_12345",
		"smoke-a",
		function(res) on_reg(res, "a") end
	)
	state.b.auth.register(
		"smoke_b_" .. tostring(math.random(1e9)),
		"smoke_pw_12345",
		"smoke-b",
		function(res) on_reg(res, "b") end
	)
end

function M._connect_and_queue()
	local connected_a, connected_b = false, false

	state.a.realtime.init(state.a)
	state.b.realtime.init(state.b)

	state.a.realtime.on("connected", function()
		connected_a = true
		M._maybe_queue(connected_a, connected_b)
	end)
	state.b.realtime.on("connected", function()
		connected_b = true
		M._maybe_queue(connected_a, connected_b)
	end)

	-- Register match.matched handlers BEFORE queueing.
	state.a.realtime.on("match_matched", function(payload)
		state.match_a = payload
		M._maybe_check_match()
	end)
	state.b.realtime.on("match_matched", function(payload)
		state.match_b = payload
		M._maybe_check_match()
	end)

	state.a.realtime.on("match_state", function(payload)
		if state.match_a == nil then return end
		local me = (payload.players or {})[state.a.player_id]
		if not me or me.x == nil then return end

		if state.x_initial == nil then
			-- Scenario 3 step 2: capture x from the FIRST observed match.state.
			state.x_initial = me.x
			log("match.state initial: x_initial = " .. tostring(me.x))
			M._send_input()
			return
		end

		-- Scenario 3 step 4: assert subsequent state shows x advanced.
		if not state.input_sent then return end
		if me.x > state.x_initial + X_DELTA then
			log("match.state confirmed: x = " .. tostring(me.x)
				.. " (initial " .. tostring(state.x_initial)
				.. ", delta > " .. tostring(X_DELTA) .. ")")
			pass()
		end
	end)

	state.a.realtime.connect()
	state.b.realtime.connect()
end

function M._maybe_queue(connected_a, connected_b)
	if not (connected_a and connected_b) then return end
	if state.queued then return end
	state.queued = true
	log("Both connected; queueing.")
	state.a.realtime.add_to_matchmaker({ mode = MATCH_MODE })
	state.b.realtime.add_to_matchmaker({ mode = MATCH_MODE })
end

function M._maybe_check_match()
	if state.match_a == nil or state.match_b == nil then return end
	if state.match_checked then return end
	state.match_checked = true
	if state.match_a.match_id ~= state.match_b.match_id then
		fail("match_id mismatch: " .. tostring(state.match_a.match_id)
			.. " vs " .. tostring(state.match_b.match_id))
		return
	end
	log("Both matched, match_id = " .. state.match_a.match_id)
	-- Do NOT send input yet. Wait for the first match.state so we can
	-- capture x_initial against the random spawn x in [50, 700].
end

function M._send_input()
	if state.input_sent then return end
	state.input_sent = true
	log("Sending match.input {move_x=1, move_y=0}")
	state.a.realtime.send_match_input({ move_x = 1, move_y = 0 })
end

--- Call from main.script on_update to enforce timeouts.
function M.update()
	if state == nil or state.done then return end
	local elapsed = socket.gettime() - state.started_at
	if elapsed > MATCH_TIMEOUT + STATE_TIMEOUT + 5 then
		if state.match_a == nil then fail("timeout waiting for match.matched")
		elseif state.x_initial == nil then fail("timeout waiting for first match.state")
		else fail("timeout waiting for match.state with input applied (x_initial="
			.. tostring(state.x_initial) .. ")")
		end
	end
	if state.done and state.done_callback then
		state.done_callback(state.ok)
		state.done_callback = nil
	end
end

return M
