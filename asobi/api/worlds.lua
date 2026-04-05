local http_mod = require("asobi.http")

local M = {}

function M.list(client, mode, callback)
	local query = nil
	if mode then query = {mode = mode} end
	http_mod.get(client, "/api/v1/worlds", query, callback)
end

function M.get(client, world_id, callback)
	http_mod.get(client, "/api/v1/worlds/" .. world_id, nil, callback)
end

function M.create(client, mode, callback)
	http_mod.post(client, "/api/v1/worlds", {mode = mode}, callback)
end

return M
