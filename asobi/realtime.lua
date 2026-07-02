local M = {}
M.__index = M

-- Server wire `type` -> SDK callback name. Must stay in sync with the
-- asobi protocol fixture corpus (see tests/fixtures/) — the dispatch
-- test in tests/test_dispatch.lua loads every fixture and asserts the
-- matching callback fires.
local SERVER_EVENTS = {
	["error"] = "error",
	["session.connected"] = "connected",
	["session.heartbeat"] = "heartbeat",
	["match.state"] = "match_state",
	["match.matched"] = "match_matched",
	["match.joined"] = "match_joined",
	["match.left"] = "match_left",
	["match.finished"] = "match_finished",
	["match.matchmaker_expired"] = "matchmaker_expired",
	["match.matchmaker_failed"] = "matchmaker_failed",
	["match.vote_start"] = "vote_start",
	["match.vote_tally"] = "vote_tally",
	["match.vote_result"] = "vote_result",
	["match.vote_vetoed"] = "vote_vetoed",
	["matchmaker.queued"] = "matchmaker_queued",
	["matchmaker.removed"] = "matchmaker_removed",
	["chat.joined"] = "chat_joined",
	["chat.left"] = "chat_left",
	["chat.message"] = "chat_message",
	["dm.sent"] = "dm_sent",
	["dm.message"] = "dm_message",
	["presence.updated"] = "presence_changed",
	["notification.new"] = "notification",
	["vote.cast_ok"] = "vote_cast_ok",
	["vote.veto_ok"] = "vote_veto_ok",
	["world.tick"] = "world_tick",
	["world.terrain"] = "world_terrain",
	["world.list"] = "world_list",
	["world.joined"] = "world_joined",
	["world.left"] = "world_left",
	["world.phase_changed"] = "phase_changed",
	["world.finished"] = "world_finished",
}

function M.new(client)
	return setmetatable({
		client = client,
		connection = nil,
		cid_counter = 0,
		pending = {},
		callbacks = {},
		entities = {},
		local_player_id = nil,
	}, M)
end

function M:on(event, callback)
	self.callbacks[event] = callback
end

local function fire(self, event, ...)
	local cb = self.callbacks[event]
	if cb then cb(...) end
end

function M:connect()
	if self.connection then return end
	local params = {}
	self.connection = websocket.connect(self.client.ws_url, params, function(_self, conn, data)
		if data.event == websocket.EVENT_CONNECTED then
			self:_send("session.connect", {token = self.client.access_token})
		elseif data.event == websocket.EVENT_DISCONNECTED then
			self.connection = nil
			local reason = data.message or "closed"
			if M._is_auth_close(reason) then
				fire(self, "auth_expired", reason)
			else
				fire(self, "disconnected", reason)
			end
		elseif data.event == websocket.EVENT_MESSAGE then
			self:_handle_message(data.message)
		elseif data.event == websocket.EVENT_ERROR then
			fire(self, "error", {error = data.message})
		end
	end)
end

function M:disconnect()
	if self.connection then
		websocket.disconnect(self.connection)
		self.connection = nil
	end
end

-- Re-authenticate a live socket with the current access_token. Called
-- after a REST refresh rotates the pair so the socket is not left holding
-- a burned token. No-op if not connected.
function M:reauth()
	if not self.connection then return end
	self:_send("session.connect", {token = self.client.access_token})
end

local AUTH_CLOSE_REASONS = {
	session_revoked = true,
	invalid_token = true,
	idle_auth_timeout = true,
}

function M._is_auth_close(reason)
	if type(reason) ~= "string" then return false end
	for key in pairs(AUTH_CLOSE_REASONS) do
		if string.find(reason, key, 1, true) then return true end
	end
	return false
end

function M:join_match(match_id)
	self:_send("match.join", {match_id = match_id})
end

function M:send_match_input(input)
	self:_send_fire_and_forget("match.input", input)
end

function M:leave_match()
	self:_send("match.leave", {})
end

function M:add_to_matchmaker(opts)
	local payload = {mode = "default"}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
		payload.mode = opts.mode or "default"
		if opts.properties then payload.properties = opts.properties end
		if opts.party then payload.party = opts.party end
	end
	self:_send("matchmaker.add", payload)
end

function M:remove_from_matchmaker(ticket_id)
	self:_send("matchmaker.remove", {ticket_id = ticket_id})
end

function M:join_chat(channel_id)
	self:_send("chat.join", {channel_id = channel_id})
end

function M:send_chat_message(channel_id, content)
	self:_send_fire_and_forget("chat.send", {channel_id = channel_id, content = content})
end

function M:leave_chat(channel_id)
	self:_send("chat.leave", {channel_id = channel_id})
end

function M:cast_vote(vote_id, option_id)
	self:_send("vote.cast", {vote_id = vote_id, option_id = option_id})
end

function M:cast_veto(vote_id)
	self:_send("vote.veto", {vote_id = vote_id})
end

function M:send_dm(recipient_id, content)
	self:_send("dm.send", {recipient_id = recipient_id, content = content})
end

function M:update_presence(status)
	self:_send("presence.update", {status = status or "online"})
end

function M:send_heartbeat()
	self:_send_fire_and_forget("session.heartbeat", {})
end

-- Round-trip a session.heartbeat and report the elapsed time. The server
-- echoes the heartbeat with the same cid, so this is the cheapest way for
-- a game to surface live RTT (e.g. in a HUD).
function M:ping(callback)
	if not self.connection then
		if callback then
			callback(nil, "not connected")
		end
		return
	end
	local t0 = socket.gettime()
	self:_send_with_callback("session.heartbeat", {}, function(_payload, err)
		if err then
			if callback then
				callback(nil, err)
			end
			return
		end
		local rtt_ms = math.floor((socket.gettime() - t0) * 1000 + 0.5)
		if callback then
			callback(rtt_ms, nil)
		end
	end)
end

function M:list_worlds(opts, callback)
	local payload = {}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
		if opts.mode then payload.mode = opts.mode end
		if opts.has_capacity ~= nil then payload.has_capacity = opts.has_capacity end
	end
	self:_send_with_callback("world.list", payload, callback)
end

function M:create_world(mode, callback)
	self:_send_with_callback("world.create", {mode = mode}, callback)
end

function M:join_world(world_id, callback)
	self:_send_with_callback("world.join", {world_id = world_id}, callback)
end

function M:find_or_create_world(mode, callback)
	self:_send_with_callback("world.find_or_create", {mode = mode}, callback)
end

function M:send_world_input(input)
	self:_send_fire_and_forget("world.input", input)
end

function M:leave_world()
	self:_send("world.leave", {})
end

function M:_send(msg_type, payload)
	if not self.connection then return end
	self.cid_counter = self.cid_counter + 1
	local msg = json.encode({type = msg_type, payload = payload, cid = tostring(self.cid_counter)})
	websocket.send(self.connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

function M:_send_with_callback(msg_type, payload, callback)
	if not self.connection then
		if callback then callback(nil, "not connected") end
		return
	end
	self.cid_counter = self.cid_counter + 1
	local cid = tostring(self.cid_counter)
	if callback then
		self.pending[cid] = callback
	end
	local msg = json.encode({type = msg_type, payload = payload, cid = cid})
	websocket.send(self.connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

function M:_send_fire_and_forget(msg_type, payload)
	if not self.connection then return end
	local msg = json.encode({type = msg_type, payload = payload})
	websocket.send(self.connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

-- Applies one server update to the managed entity registry, returning
-- {kind, id, state, changed_fields} so callers can fire callbacks. The
-- server emits PARTIAL diffs on op="u" — only fields that changed —
-- so we MUST merge against the last known state, not overwrite.
function M:_apply_entity_update(u)
	local id = u.id
	if not id then return nil end
	local op = u.op
	if op == "a" then
		local state = {}
		for k, v in pairs(u) do
			if k ~= "op" and k ~= "id" then state[k] = v end
		end
		self.entities[id] = state
		return {kind = "added", id = id, state = state}
	elseif op == "u" then
		local existing = self.entities[id]
		if not existing then
			existing = {}
			self.entities[id] = existing
		end
		local changed = {}
		for k, v in pairs(u) do
			if k ~= "op" and k ~= "id" then
				if existing[k] ~= v then
					existing[k] = v
					changed[#changed + 1] = k
				end
			end
		end
		if #changed == 0 then return nil end
		return {kind = "updated", id = id, state = existing, changed = changed}
	elseif op == "r" then
		self.entities[id] = nil
		return {kind = "removed", id = id}
	end
	return nil
end

-- Processes a tick frame (world.tick or match.state). Applies all
-- updates to the registry, fires per-entity callbacks, then fires
-- on_tick once at the end so game code can do per-frame UI work.
function M:_dispatch_tick(payload)
	local updates = payload and payload.updates or {}
	for i = 1, #updates do
		local change = self:_apply_entity_update(updates[i])
		if change then
			if change.kind == "added" then
				fire(self, "entity_added", change.id, change.state)
			elseif change.kind == "updated" then
				fire(self, "entity_updated", change.id, change.state, change.changed)
			elseif change.kind == "removed" then
				fire(self, "entity_removed", change.id)
			end
		end
	end
	fire(self, "tick", payload.tick, payload)
end

function M:_handle_message(raw)
	local msg = json.decode(raw)
	if not msg then return end

	local msg_type = msg.type or ""
	local payload = msg.payload or {}
	local cid = msg.cid

	if cid and self.pending[cid] then
		local cb = self.pending[cid]
		self.pending[cid] = nil
		if msg_type == "error" then
			cb(nil, payload.reason or "unknown error")
		else
			cb(payload, nil)
		end
		return
	end

	-- Both message types carry the same {tick, updates} shape; route both
	-- through the same merge so games stay independent of which one fires.
	if msg_type == "world.tick" or msg_type == "match.state" then
		self:_dispatch_tick(payload)
	end

	if msg_type == "session.connected" and payload.player_id then
		self.local_player_id = payload.player_id
	end

	-- Reset the entity registry on world transitions so stale ghosts
	-- don't survive a re-join into a fresh zone.
	if msg_type == "world.joined" or msg_type == "world.left" then
		self.entities = {}
	end

	-- A server error rejecting the access_token (bad/expired/revoked) is an
	-- auth failure, not a transient protocol error: surface it as such so
	-- games force a re-login instead of retrying a dead token.
	if msg_type == "error" and M._is_auth_close(payload.reason) then
		fire(self, "auth_expired", payload.reason)
	end

	local event = SERVER_EVENTS[msg_type]
	if event then fire(self, event, payload) end
end

return M
