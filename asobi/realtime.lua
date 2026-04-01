local M = {}

M._client = nil
M._connection = nil
M._cid_counter = 0
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
	on_error = nil,
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

function M.add_to_matchmaker(mode)
	M._send("matchmaker.add", {mode = mode or "default"})
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

function M.update_presence(status)
	M._send("presence.update", {status = status or "online"})
end

function M.send_heartbeat()
	M._send_fire_and_forget("session.heartbeat", {})
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

function M._send_fire_and_forget(msg_type, payload)
	if not M._connection then return end
	local msg = json.encode({type = msg_type, payload = payload})
	websocket.send(M._connection, msg, {type = websocket.DATA_TYPE_TEXT})
end

function M._handle_message(raw)
	local msg = json.decode(raw)
	if not msg then return end

	local msg_type = msg.type or ""
	local payload = msg.payload or {}

	local handlers = {
		["session.connected"] = "on_connected",
		["match.state"] = "on_match_state",
		["match.started"] = "on_match_started",
		["match.finished"] = "on_match_finished",
		["match.vote_start"] = "on_vote_start",
		["match.vote_tally"] = "on_vote_tally",
		["match.vote_result"] = "on_vote_result",
		["match.vote_vetoed"] = "on_vote_vetoed",
		["chat.message"] = "on_chat_message",
		["notification.new"] = "on_notification",
		["match.matched"] = "on_matchmaker_matched",
		["presence.changed"] = "on_presence_changed",
		["error"] = "on_error",
	}

	local handler_name = handlers[msg_type]
	if handler_name and M._callbacks[handler_name] then
		M._callbacks[handler_name](payload)
	end
end

return M
