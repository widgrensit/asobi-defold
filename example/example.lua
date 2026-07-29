-- example.lua - the full connect -> matchmake -> in-a-match loop.
--
-- Attach this to a script on a game object in your MAIN collection: a script
-- that stays loaded for the whole session, NOT a gui_script or a script on an
-- object that gets removed on a scene change. Defold drops the websocket
-- callbacks when their owning script unloads, so you would send fine but stop
-- receiving events (match_matched, match_state, ...).

local asobi = require("asobi.client")

local client

function init(self)
	client = asobi.create("localhost", 8084)

	-- 1. Guest sign-in. No account needed; async, returns (data, err).
	client.auth.guest_device(client, function(data, err)
		if err then
			print("guest sign-in failed: " .. tostring(err.error))
			return
		end
		print("signed in, player_id=" .. data.player_id)

		local rt = client.realtime

		-- 2. Register EVERY handler once, before connect(). They stay live for
		--    the whole session. Registering after connect() can miss events.
		rt:on("connected", function(_payload)
			-- 3. Queue only after the socket is up.
			rt:add_to_matchmaker("demo")
			print("queued for 'demo'")
		end)

		-- The server confirms your ticket with matchmaker_queued, then sends
		-- match_matched when you are in (the matchmaker auto-joins you; there is
		-- no separate join step).
		rt:on("matchmaker_queued", function(p) print("queued, ticket " .. p.ticket_id) end)
		rt:on("match_matched", function(p) print("matched! " .. p.match_id) end)
		rt:on("match_state", function(_s) print("match_state received") end)

		-- Always handle these two, or a bad mode / crashed match fails silently.
		rt:on("error", function(p) print("error: " .. tostring(p.reason or p.type)) end)
		rt:on("matchmaker_failed", function(p) print("matchmaking failed: " .. tostring(p.reason)) end)

		rt:connect()
	end)
end

-- The 'demo' mode in sdk_demo_backend needs 2 players (match_size = 2), so a
-- single client stays queued (you will see 'queued' but not 'matched'). Run two
-- instances to see a match form, or set match_size = 1 in the mode's match.lua
-- and restart the backend (match_size is read at boot).
