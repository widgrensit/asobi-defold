local http_mod = require("asobi.http")

local M = {}

function M.get(client, player_id, callback)
	http_mod.get(client, "/api/v1/players/" .. player_id, nil, callback)
end

function M.update(client, player_id, fields, callback)
	http_mod.put(client, "/api/v1/players/" .. player_id, fields, callback)
end

function M.get_self(client, callback)
	M.get(client, client.player_id, callback)
end

return M
