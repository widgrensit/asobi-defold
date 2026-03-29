local asobi = require("asobi.client")

local client

function init(self)
	client = asobi.create("localhost", 8080)

	-- Login
	client.auth.login(client, "player1", "secret123", function(data, err)
		if err then
			print("Login failed: " .. err.error)
			return
		end
		print("Logged in as: " .. data.username)

		-- Get profile
		client.players.get_self(client, function(player, err)
			if not err then
				print("Display name: " .. player.display_name)
			end
		end)

		-- Submit score
		client.leaderboards.submit_score(client, "weekly", 1500, 0, function(entry, err)
			if not err then
				print("Score submitted")
			end
		end)

		-- Connect realtime
		client.realtime.on("matchmaker_matched", function(payload)
			print("Match found: " .. payload.match_id)
			client.realtime.join_match(payload.match_id)
		end)

		client.realtime.on("match_state", function(payload)
			print("Tick: " .. tostring(payload.tick))
		end)

		client.realtime.connect()
		client.realtime.add_to_matchmaker("arena")
	end)
end
