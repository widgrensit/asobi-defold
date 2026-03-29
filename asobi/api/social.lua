local http_mod = require("asobi.http")

local M = {}

function M.get_friends(client, status, limit, callback)
	local query = {limit = limit or 50}
	if status then query.status = status end
	http_mod.get(client, "/api/v1/friends", query, callback)
end

function M.add_friend(client, friend_id, callback)
	http_mod.post(client, "/api/v1/friends", {friend_id = friend_id}, callback)
end

function M.accept_friend(client, friend_id, callback)
	http_mod.put(client, "/api/v1/friends/" .. friend_id, {status = "accepted"}, callback)
end

function M.block_friend(client, friend_id, callback)
	http_mod.put(client, "/api/v1/friends/" .. friend_id, {status = "blocked"}, callback)
end

function M.remove_friend(client, friend_id, callback)
	http_mod.delete(client, "/api/v1/friends/" .. friend_id, callback)
end

function M.create_group(client, name, description, max_members, open, callback)
	http_mod.post(client, "/api/v1/groups", {
		name = name,
		description = description or "",
		max_members = max_members or 50,
		open = open or false,
	}, callback)
end

function M.get_group(client, group_id, callback)
	http_mod.get(client, "/api/v1/groups/" .. group_id, nil, callback)
end

function M.join_group(client, group_id, callback)
	http_mod.post(client, "/api/v1/groups/" .. group_id .. "/join", nil, callback)
end

function M.leave_group(client, group_id, callback)
	http_mod.post(client, "/api/v1/groups/" .. group_id .. "/leave", nil, callback)
end

function M.get_chat_history(client, channel_id, callback)
	http_mod.get(client, "/api/v1/chat/" .. channel_id .. "/history", nil, callback)
end

return M
