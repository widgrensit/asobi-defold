local http_mod = require("asobi.http")

local M = {}

function M.register(client, username, password, display_name, callback)
	http_mod.post(client, "/api/v1/auth/register", {
		username = username,
		password = password,
		display_name = display_name or username,
	}, function(data, err)
		if not err and data then
			client.session_token = data.session_token
			client.player_id = data.player_id
		end
		if callback then callback(data, err) end
	end)
end

function M.login(client, username, password, callback)
	http_mod.post(client, "/api/v1/auth/login", {
		username = username,
		password = password,
	}, function(data, err)
		if not err and data then
			client.session_token = data.session_token
			client.player_id = data.player_id
		end
		if callback then callback(data, err) end
	end)
end

function M.oauth(client, provider, token, callback)
	http_mod.post(client, "/api/v1/auth/oauth", {
		provider = provider,
		token = token,
	}, function(data, err)
		if not err and data then
			client.session_token = data.session_token
			client.player_id = data.player_id
		end
		if callback then callback(data, err) end
	end)
end

function M.link_provider(client, provider, token, callback)
	http_mod.post(client, "/api/v1/auth/link", {
		provider = provider,
		token = token,
	}, callback)
end

function M.unlink_provider(client, provider, callback)
	http_mod.delete(client, "/api/v1/auth/unlink?provider=" .. http_mod._urlencode(provider), callback)
end

function M.refresh(client, callback)
	http_mod.post(client, "/api/v1/auth/refresh", {
		session_token = client.session_token,
	}, function(data, err)
		if not err and data then
			client.session_token = data.session_token
		end
		if callback then callback(data, err) end
	end)
end

function M.logout(client)
	client.session_token = nil
	client.player_id = nil
end

return M
