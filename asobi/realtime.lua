local M = {}

M._client = nil
M._connection = nil
M._cid_counter = 0
M._pending = {}

-- Managed entity registry. The SDK applies partial-diff merging from
-- world.tick / match.state frames so games don't have to. Indexed by
-- entity id; values are the latest known full state for that entity.
M.entities = {}
M.local_player_id = nil

M._callbacks = {
	on_connected = nil,
	on_disconnected = nil,
	on_match_state = nil,
	on_match_started = nil,
	on_match_finished = nil,
	on_vote_start = nil,
	on_vote_tally = nil,
	on_vote_result = nil,
	on_vote_vetoed = nil,
	on_chat_message = nil,
	on_notification = nil,
	on_matchmaker_matched = nil,
	on_presence_changed = nil,
	on_dm_message = nil,
	on_world_list = nil,
	on_world_joined = nil,
	on_world_left = nil,
	on_world_tick = nil,
	on_world_terrain = nil,
	on_phase_changed = nil,
	on_world_finished = nil,
	on_match_joined = nil,
	on_match_left = nil,
	on_matchmaker_queued = nil,
	on_error = nil,
	-- High-level entity-sync callbacks (post-merge).
	on_entity_added = nil,
	on_entity_updated = nil,
	on_entity_removed = nil,
	on_tick = nil,
}

function M.init(client)
	M._client = client
end

function M.connect()
	if M._connection then return end
	local params = {}
	M._connection = websocket.connect(M._client.ws_url, params, function(self, conn, data)
		if data.event == websocket.EVENT_CONNECTED then
			M._send("session.connect", {token = M._client.session_token})
		elseif data.event == websocket.EVENT_DISCONNECTED then
			M._connection = nil
			if M._callbacks.on_disconnected then
				M._callbacks.on_disconnected(data.message or "closed")
			end
		elseif data.event == websocket.EVENT_MESSAGE then
			M._handle_message(data.message)
		elseif data.event == websocket.EVENT_ERROR then
			if M._callbacks.on_error then
				M._callbacks.on_error({error = data.message})
			end
		end
	end)
end

function M.disconnect()
	if M._connection then
		websocket.disconnect(M._connection)
		M._connection = nil
	end
end

function M.join_match(match_id)
	M._send("match.join", {match_id = match_id})
end

function M.send_match_input(input)
	M._send_fire_and_forget("match.input", input)
end

function M.leave_match()
	M._send("match.leave", {})
end

function M.add_to_matchmaker(opts)
	local payload = {mode = "default"}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
		payload.mode = opts.mode or "default"
		if opts.properties then payload.properties = opts.properties end
		if opts.party then payload.party = opts.party end
	end
	M._send("matchmaker.add", payload)
end

function M.remove_from_matchmaker(ticket_id)
	M._send("matchmaker.remove", {ticket_id = ticket_id})
end

function M.join_chat(channel_id)
	M._send("chat.join", {channel_id = channel_id})
end

function M.send_chat_message(channel_id, content)
	M._send_fire_and_forget("chat.send", {channel_id = channel_id, content = content})
end

function M.leave_chat(channel_id)
	M._send("chat.leave", {channel_id = channel_id})
end

function M.cast_vote(vote_id, option_id)
	M._send("vote.cast", {vote_id = vote_id, option_id = option_id})
end

function M.cast_veto(vote_id)
	M._send("vote.veto", {vote_id = vote_id})
end

function M.send_dm(recipient_id, content)
	M._send("dm.send", {recipient_id = recipient_id, content = content})
end

function M.update_presence(status)
	M._send("presence.update", {status = status or "online"})
end

function M.send_heartbeat()
	M._send_fire_and_forget("session.heartbeat", {})
end

function M.list_worlds(opts, callback)
	local payload = {}
	if type(opts) == "string" then
		payload.mode = opts
	elseif type(opts) == "table" then
		if opts.mode then payload.mode = opts.mode end
		if opts.has_capacity ~= nil then payload.has_capacity = opts.has_capacity end
	end
	M._send_with_callback("world.list", payload, callback)
end

function M.create_world(mode, callback)
	M._send_with_callback("world.create", {mode = mode}, callback)
end

function M.join_world(world_id, callback)
	M._send_with_callback("world.join", {world_id = world_id}, callback)
end

function M.find_or_create_world(mode, callback)
	M._send_with_callback("world.find_or_create", {mode = mode}, callback)
end

function M.send_world_input(input)
	M._send_fire_and_forget("world.input", input)
end

function M.leave_world()
	M._send("world.leave", {})
end

function M.on(event, callback)
	M._callbacks["on_" .. event] = callback
end

function M._send(msg_type, payload)
	if not M._connection then return end
	M._cid_counter = M._cid_counter + 1
	local msg = json.encode({type = msg_type, payload = payload, cid = tostring(M._cid_counter)})
	websocket.send(M._connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

function M._send_with_callback(msg_type, payload, callback)
	if not M._connection then
		if callback then callback(nil, "not connected") end
		return
	end
	M._cid_counter = M._cid_counter + 1
	local cid = tostring(M._cid_counter)
	if callback then
		M._pending[cid] = callback
	end
	local msg = json.encode({type = msg_type, payload = payload, cid = cid})
	websocket.send(M._connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

function M._send_fire_and_forget(msg_type, payload)
	if not M._connection then return end
	local msg = json.encode({type = msg_type, payload = payload})
	websocket.send(M._connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

-- Applies one server update to the managed entity registry, returning
-- {kind, id, state, changed_fields} so callers can fire callbacks. The
-- server emits PARTIAL diffs on op="u" — only fields that changed —
-- so we MUST merge against the last known state, not overwrite.
function M._apply_entity_update(u)
	local id = u.id
	if not id then return nil end
	local op = u.op
	if op == "a" then
		local state = {}
		for k, v in pairs(u) do
			if k ~= "op" and k ~= "id" then state[k] = v end
		end
		M.entities[id] = state
		return {kind = "added", id = id, state = state}
	elseif op == "u" then
		local existing = M.entities[id]
		if not existing then
			-- Server sent an update for an entity we never saw added.
			-- Treat as add when full enough; otherwise stash partial.
			existing = {}
			M.entities[id] = existing
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
		M.entities[id] = nil
		return {kind = "removed", id = id}
	end
	return nil
end

-- Processes a tick frame (world.tick or match.state). Applies all
-- updates to the registry, fires per-entity callbacks, then fires
-- on_tick once at the end so game code can do per-frame UI work.
function M._dispatch_tick(payload)
	local updates = payload and payload.updates or {}
	for i = 1, #updates do
		local change = M._apply_entity_update(updates[i])
		if change then
			if change.kind == "added" and M._callbacks.on_entity_added then
				M._callbacks.on_entity_added(change.id, change.state)
			elseif change.kind == "updated" and M._callbacks.on_entity_updated then
				M._callbacks.on_entity_updated(change.id, change.state, change.changed)
			elseif change.kind == "removed" and M._callbacks.on_entity_removed then
				M._callbacks.on_entity_removed(change.id)
			end
		end
	end
	if M._callbacks.on_tick then
		M._callbacks.on_tick(payload.tick, payload)
	end
end

function M._handle_message(raw)
	local msg = json.decode(raw)
	if not msg then return end

	local msg_type = msg.type or ""
	local payload = msg.payload or {}
	local cid = msg.cid

	-- Check for pending request-response callbacks
	if cid and M._pending[cid] then
		local cb = M._pending[cid]
		M._pending[cid] = nil
		if msg_type == "error" then
			cb(nil, payload.reason or "unknown error")
		else
			cb(payload, nil)
		end
		return
	end

	-- Dispatch entity-sync frames through the managed registry.
	-- Both message types carry the same {tick, updates} shape, but they
	-- come from different game-mode paths (world vs match). Routing both
	-- through the same merge keeps games independent of which one fires.
	if msg_type == "world.tick" or msg_type == "match.state" then
		M._dispatch_tick(payload)
	end

	-- Capture local_player_id so games can identify "self" without
	-- threading it through their own state.
	if msg_type == "session.connected" and payload.player_id then
		M.local_player_id = payload.player_id
	end

	-- Reset the entity registry on world transitions so stale ghosts
	-- don't survive a re-join into a fresh zone.
	if msg_type == "world.joined" or msg_type == "world.left" then
		M.entities = {}
	end

	local handlers = {
		["session.connected"] = "on_connected",
		["match.state"] = "on_match_state",
		["match.started"] = "on_match_started",
		["match.finished"] = "on_match_finished",
		["match.joined"] = "on_match_joined",
		["match.left"] = "on_match_left",
		["match.vote_start"] = "on_vote_start",
		["match.vote_tally"] = "on_vote_tally",
		["match.vote_result"] = "on_vote_result",
		["match.vote_vetoed"] = "on_vote_vetoed",
		["chat.message"] = "on_chat_message",
		["notification.new"] = "on_notification",
		["matchmaker.queued"] = "on_matchmaker_queued",
		["matchmaker.matched"] = "on_matchmaker_matched",
		["presence.updated"] = "on_presence_changed",
		["dm.message"] = "on_dm_message",
		["world.list"] = "on_world_list",
		["world.joined"] = "on_world_joined",
		["world.left"] = "on_world_left",
		["world.tick"] = "on_world_tick",
		["world.terrain"] = "on_world_terrain",
		["world.phase_changed"] = "on_phase_changed",
		["world.finished"] = "on_world_finished",
		["error"] = "on_error",
	}

	local handler_name = handlers[msg_type]
	if handler_name and M._callbacks[handler_name] then
		M._callbacks[handler_name](payload)
	end
end

return M
