-- quickstart.lua - the shortest path into a match, using asobi.quick_start.
--
-- Attach to a script on a game object in your MAIN collection (one that stays
-- loaded the whole session). Defold drops websocket callbacks when the owning
-- script unloads, so avoid a gui_script or a soon-removed object.
--
-- quick_start does guest sign-in, connects, and queues for you, in the right
-- order (registering handlers before connect, which is the trap everyone hits).
-- For entity-sync or custom match state, use the explicit flow in example.lua.

local asobi = require("asobi.client")

function init(self)
	self.client = asobi.quick_start({
		host = "grid-hackers-gridhackers.pendragames.asobi.dev", -- your env
		mode = "default",                                        -- your mode
		on_queued = function(p)
			print("queued: ticket " .. p.ticket_id .. ", need " .. tostring(p.players_needed) .. " more")
		end,
		on_matched = function(p) print("matched! match " .. p.match_id) end,
		on_failed = function(p) print("failed: " .. tostring(p.reason)) end,
	})
end

function final(self)
	-- Tidy up if this object ever unloads.
	if self.client then self.client.realtime:disconnect() end
end

-- With match_size = 1 on the mode you match instantly on your own; with 2+ you
-- stay 'queued' until a second client joins.
