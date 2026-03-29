local http_mod = require("asobi.http")

local M = {}

function M.list(client, callback)
	http_mod.get(client, "/api/v1/matches", nil, callback)
end

function M.get(client, match_id, callback)
	http_mod.get(client, "/api/v1/matches/" .. match_id, nil, callback)
end

return M
