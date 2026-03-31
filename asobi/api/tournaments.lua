local http_mod = require("asobi.http")

local M = {}

function M.list(client, callback)
	http_mod.get(client, "/api/v1/tournaments", nil, callback)
end

function M.get(client, tournament_id, callback)
	http_mod.get(client, "/api/v1/tournaments/" .. tournament_id, nil, callback)
end

function M.join(client, tournament_id, callback)
	http_mod.post(client, "/api/v1/tournaments/" .. tournament_id .. "/join", {}, callback)
end

return M
