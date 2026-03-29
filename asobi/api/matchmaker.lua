local http_mod = require("asobi.http")

local M = {}

function M.add(client, mode, callback)
	http_mod.post(client, "/api/v1/matchmaker", {mode = mode or "default"}, callback)
end

function M.status(client, ticket_id, callback)
	http_mod.get(client, "/api/v1/matchmaker/" .. ticket_id, nil, callback)
end

function M.cancel(client, ticket_id, callback)
	http_mod.delete(client, "/api/v1/matchmaker/" .. ticket_id, callback)
end

return M
