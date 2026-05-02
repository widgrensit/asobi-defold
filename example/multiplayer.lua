-- Multiplayer entity-sync example.
-- Demonstrates the high-level entity-sync API: register on_entity_*
-- callbacks and the SDK does partial-diff merging for you.

local asobi = require("asobi.client")

local client
local ghosts = {} -- id -> game object url for remote players

function init(self)
	client = asobi.create("localhost", 8084)

	client.auth.register(
		client,
		"player_" .. tostring(math.random(1, 1e9)),
		"pass1234",
		nil,
		function(data, err)
			if err then
				print("register failed: " .. err)
				return
			end

			-- A new ghost appears (someone joined or we just got an initial snapshot).
			client.realtime:on("entity_added", function(id, state)
				if id == client.realtime.local_player_id then
					return
				end
				print(
					"[example] ghost "
						.. id
						.. " appeared at ("
						.. tostring(state.x)
						.. ","
						.. tostring(state.y)
						.. ")"
				)
				-- factory.create("#ghost_factory", vmath.vector3(state.x, state.y, 0), ...)
				ghosts[id] = "<go_url>"
			end)

			-- A ghost moved. `state` is the FULL merged state, never partial.
			-- The SDK already merged the diff against the previous state.
			client.realtime:on("entity_updated", function(id, state, changed)
				if id == client.realtime.local_player_id then
					return
				end
				-- go.set_position(vmath.vector3(state.x, state.y, 0), ghosts[id])
				print(
					"[example] " .. id .. " moved to (" .. tostring(state.x) .. "," .. tostring(state.y) .. ")"
				)
			end)

			client.realtime:on("entity_removed", function(id)
				if ghosts[id] then
					-- go.delete(ghosts[id])
					ghosts[id] = nil
				end
			end)

			client.realtime:connect()
			client.realtime:find_or_create_world("hub", function(payload, err)
				if err then
					print("join failed: " .. err)
					return
				end
				print("[example] joined world " .. payload.world_id)
				-- Send a move to test.
				timer.delay(0.5, false, function()
					client.realtime:send_world_input({ action = "move", x = 500, y = 200 })
				end)
			end)
		end
	)
end
