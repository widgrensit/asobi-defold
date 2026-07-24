-- Guest / anonymous auth example.
--
-- A guest is a real player (with a persistent player_id) that needs no username
-- or password. The device holds a {device_id, device_secret} keypair; the same
-- pair resumes the same player on every launch. `guest_device` manages that
-- keypair for you (generate on first run, persist, reuse) and signs in.

local asobi = require("asobi.client")

local client

function init(self)
	client = asobi.create("localhost", 8084)

	-- --- The one-call flow (recommended) --------------------------------
	-- Generates + saves the keypair on first run, reuses it after, signs in.
	client.auth.guest_device(client, function(data, err)
		if err then
			print("guest sign-in failed: " .. tostring(err.error))
			return
		end

		-- player_id is who you are in the backend - use it for everything.
		self.player_id = data.player_id

		if data.created then
			print("brand-new guest: " .. data.player_id)
			-- ... run first-time onboarding here ...
		else
			print("welcome back, guest: " .. data.player_id)
		end

		-- You now have an authenticated session. Do backend things:
		client.leaderboards.submit_score(client, "weekly", 1500, 0, function(_, e)
			if not e then print("score submitted") end
		end)

		client.realtime:connect()
		client.realtime:add_to_matchmaker("arena")
	end)
end

-- --- Turning a guest into a real account --------------------------------
-- Call this (after a successful guest sign-in) when the player wants their
-- progress to survive a reinstall or move to another device. The player_id is
-- KEPT - nothing is lost; a username/password is just added to the same player.
function upgrade_to_account(username, password)
	client.auth.upgrade_guest(client, username, password, function(data, err)
		if err then
			print("upgrade failed: " .. tostring(err.error))
			return
		end
		print("account claimed, same player_id: " .. tostring(data.player_id))
	end)
end

-- --- Options: custom storage or a stronger RNG --------------------------
-- For production, back the secret with a real CSPRNG (crypto extension); you
-- can also choose where it is stored.
function init_with_options(self)
	client = asobi.create("localhost", 8084)

	client.auth.guest_device(client, {
		app = "mygame",         -- sys.get_save_file app name (default "asobi")
		file = "guest_device",  -- save-file name
		random_bytes = function(n)
			-- return exactly n cryptographically-random bytes from your source
			return my_csprng(n)
		end,
	}, function(data, err)
		if not err then print("signed in: " .. data.player_id) end
	end)
end

-- --- Bring your own credentials -----------------------------------------
-- If you'd rather manage the keypair yourself (e.g. an OS keychain), skip the
-- helper and pass the values to guest() directly. device_secret must be
-- standard base64 of >= 32 random bytes; device_id is any stable per-install id.
function init_manual(self)
	client = asobi.create("localhost", 8084)

	local device_id, device_secret = load_my_own_credentials()
	client.auth.guest(client, device_id, device_secret, function(data, err)
		if not err then print("signed in: " .. data.player_id) end
	end)
end
