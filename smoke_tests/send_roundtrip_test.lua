-- game.send round-trip regression, driven through the real SDK inside a
-- real Defold engine:
--
--   client: numeric command -> string, send_match_input({message = command})
--   server: handle_input counts inputs and echoes via game.send
--   client: game_message callback must receive the echo
--
-- game.send was silently dropped server-side (asobi#235) and then again by
-- a stale image pin (asobi_lua#101/#103); this asserts the whole path.

local asobi = require("asobi.client")

local M = {}

local OVERALL_TIMEOUT = 30.0
local MATCH_MODE = "echo"

local state = nil

local function log(msg)
	print("[roundtrip] " .. tostring(msg))
end

local function fail(msg)
	if state.done then return end
	print("[roundtrip] FAIL: " .. tostring(msg))
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

local function send_command(client, n)
	-- The shape a typical first game uses: a numeric command mapped to a
	-- string, sent as {message = command}.
	local command = n
	if command == 1 then command = "up"
	elseif command == 2 then command = "down"
	elseif command == 3 then command = "left"
	elseif command == 4 then command = "right"
	end
	log("sending match.input {message=" .. command .. "}")
	client.realtime:send_match_input({message = command})
end

function M.run(host, port, done_callback)
	state = {
		echoes = {},
		done = false,
		ok = false,
		started_at = socket.gettime(),
		done_callback = done_callback,
	}

	local c = asobi.create(host, port)
	local user = "rt_def_" .. rand_suffix()

	c.realtime:on("error", function(payload)
		fail("server error: " .. tostring(payload and payload.reason))
	end)

	c.realtime:on("game_message", function(payload)
		local m = payload and payload.message
		if type(m) ~= "table" then
			fail("game_message payload.message not a table: " .. tostring(m))
			return
		end
		log("game_message echo=" .. tostring(m.echo) .. " count=" .. tostring(m.count))
		state.echoes[#state.echoes + 1] = m
		if #state.echoes == 1 then
			if m.echo ~= "up" or m.count ~= 1 then
				fail("first echo wrong: echo=" .. tostring(m.echo)
					.. " count=" .. tostring(m.count))
				return
			end
			send_command(c, 2)
		elseif #state.echoes == 2 then
			if m.echo ~= "down" or m.count ~= 2 then
				fail("second echo wrong: echo=" .. tostring(m.echo)
					.. " count=" .. tostring(m.count))
				return
			end
			pass()
		end
	end)

	c.realtime:on("match_matched", function(payload)
		-- The matchmaker auto-joins matched players; match.matched means
		-- you are in (a wire match.joined only answers an explicit join).
		log("match.matched, match_id=" .. tostring(payload.match_id) .. "; sending first input")
		send_command(c, 1)
	end)

	c.realtime:on("connected", function(payload)
		log("session.connected, player_id=" .. tostring(payload.player_id))
		c.realtime:add_to_matchmaker({mode = MATCH_MODE})
		log("queued (mode=" .. MATCH_MODE .. ")")
	end)

	log("registering " .. user)
	c.auth.register(c, user, "rt_pw_12345", user, function(data, err)
		if err then
			fail("register: " .. tostring(err.error or err))
			return
		end
		log("registered, player_id=" .. tostring(data.player_id))
		c.realtime:connect()
	end)
end

function M.update()
	if state == nil then return end
	if not state.done then
		if socket.gettime() - state.started_at > OVERALL_TIMEOUT then
			fail("timeout: echoes received = " .. tostring(#state.echoes))
		end
	end
	if state.done and state.done_callback then
		local cb = state.done_callback
		state.done_callback = nil
		cb(state.ok)
	end
end

return M
