-- Smoke test for asobi-defold against widgrensit/sdk_demo_backend.
--
-- This file is Defold-engine-specific (uses `http.request`, `websocket`
-- via the asobi SDK). It is driven by smoke_tests/headless/main.script
-- inside a Defold project; see smoke_tests/README.md.
--
-- SCOPE: full canonical SMOKE.md flow with two clients in one Lua VM.
--
-- Validates:
--   1. POST /api/v1/auth/register for two distinct players (Scenario 1, step 1).
--   2. Both /ws connect + session.connected (Scenario 1, steps 2-3).
--   3. Both queue via matchmaker.add and receive match.matched with the
--      same match_id (Scenario 2).
--   4. Client A receives match.state, sends match.input, and sees its
--      own x advance past x_initial + X_DELTA (Scenario 3).

local asobi = require("asobi.client")

local M = {}

local OVERALL_TIMEOUT = 30.0
local MATCH_MODE = "demo"
local X_DELTA = 10

local state = nil

local function log(msg)
	print("[smoke] " .. tostring(msg))
end

local function fail(msg)
	if state.done then
		return
	end
	print("[smoke] FAIL: " .. tostring(msg))
	state.done = true
	state.ok = false
end

local function pass()
	log("PASS")
	state.done = true
	state.ok = true
end

local function rand_suffix()
	return tostring(os.time()) .. "_" .. tostring(math.random(1, 1e9))
end

local function maybe_check_matched()
	if state.match_a and state.match_b and not state.match_checked then
		state.match_checked = true
		if state.match_a.match_id ~= state.match_b.match_id then
			fail(
				"match_id mismatch: "
					.. tostring(state.match_a.match_id)
					.. " vs "
					.. tostring(state.match_b.match_id)
			)
			return
		end
		log("Both matched, match_id = " .. tostring(state.match_a.match_id))
	end
end

local function wire_handlers(client, letter, on_matched_store)
	client.realtime:on("match_matched", function(payload)
		log(letter .. " match.matched, match_id=" .. tostring(payload.match_id))
		on_matched_store(payload)
		maybe_check_matched()
	end)

	client.realtime:on("error", function(payload)
		fail(letter .. " server error: " .. tostring(payload and payload.reason))
	end)
end

--- Entry point. Call from a Defold main.script on_init.
---
--- Passes `done_callback(ok)` when the test finishes (either pass or
--- fail); `ok` is true on pass.
function M.run(host, port, done_callback)
	state = {
		client_a = nil,
		client_b = nil,
		match_a = nil,
		match_b = nil,
		match_checked = false,
		x_initial = nil,
		input_sent = false,
		done = false,
		ok = false,
		started_at = socket.gettime(),
		done_callback = done_callback,
	}

	local a = asobi.create(host, port)
	local b = asobi.create(host, port)
	state.client_a = a
	state.client_b = b

	local user_a = "smoke_def_a_" .. rand_suffix()
	local user_b = "smoke_def_b_" .. rand_suffix()

	log("Registering A: " .. user_a)
	a.auth.register(a, user_a, "smoke_pw_12345", user_a, function(data, err)
		if err then
			fail("register A: " .. tostring(err.error or err))
			return
		end
		log("Registered A, player_id=" .. tostring(data.player_id))

		log("Registering B: " .. user_b)
		b.auth.register(b, user_b, "smoke_pw_12345", user_b, function(data2, err2)
			if err2 then
				fail("register B: " .. tostring(err2.error or err2))
				return
			end
			log("Registered B, player_id=" .. tostring(data2.player_id))
			M._connect_both()
		end)
	end)
end

function M._connect_both()
	local a = state.client_a
	local b = state.client_b

	wire_handlers(a, "A", function(p)
		state.match_a = p
	end)
	wire_handlers(b, "B", function(p)
		state.match_b = p
	end)

	a.realtime:on("connected", function(payload)
		log("A session.connected, player_id=" .. tostring(payload.player_id))
		a.realtime:add_to_matchmaker({ mode = MATCH_MODE })
		log("A queued (mode=" .. MATCH_MODE .. ")")
	end)

	b.realtime:on("connected", function(payload)
		log("B session.connected, player_id=" .. tostring(payload.player_id))
		b.realtime:add_to_matchmaker({ mode = MATCH_MODE })
		log("B queued (mode=" .. MATCH_MODE .. ")")
	end)

	a.realtime:on("match_state", function(payload)
		if not state.match_checked then
			return
		end
		local me = (payload.players or {})[a.player_id]
		if not me or me.x == nil then
			return
		end
		if state.x_initial == nil then
			state.x_initial = me.x
			log("A first match.state: x_initial = " .. tostring(state.x_initial))
			log("A sending match.input {move_x=1, move_y=0}")
			a.realtime:send_match_input({ move_x = 1, move_y = 0, shoot = false, aim_x = 0, aim_y = 0 })
			state.input_sent = true
			return
		end
		if state.input_sent and me.x > state.x_initial + X_DELTA then
			log(
				"A match.state confirmed: x = "
					.. tostring(me.x)
					.. " (initial "
					.. tostring(state.x_initial)
					.. ", delta > "
					.. X_DELTA
					.. ")"
			)
			pass()
		end
	end)

	a.realtime:connect()
	b.realtime:connect()
end

--- Call from main.script on_update to enforce timeouts and fire the
--- done_callback once the run resolves.
function M.update()
	if state == nil then
		return
	end
	if not state.done then
		local elapsed = socket.gettime() - state.started_at
		if elapsed > OVERALL_TIMEOUT then
			if not state.match_checked then
				fail("timeout waiting for match.matched")
			elseif state.x_initial == nil then
				fail("timeout waiting for first match.state")
			else
				fail("timeout waiting for x to advance (x_initial=" .. tostring(state.x_initial) .. ")")
			end
		end
	end
	if state.done and state.done_callback then
		if state.client_a and state.client_a.realtime then
			state.client_a.realtime:disconnect()
		end
		if state.client_b and state.client_b.realtime then
			state.client_b.realtime:disconnect()
		end
		local cb = state.done_callback
		state.done_callback = nil
		cb(state.ok)
	end
end

return M
