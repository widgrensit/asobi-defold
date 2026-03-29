local http_mod = require("asobi.http")

local M = {}

function M.list(client, callback)
	http_mod.get(client, "/api/v1/notifications", nil, callback)
end

function M.mark_read(client, notification_id, callback)
	http_mod.put(client, "/api/v1/notifications/" .. notification_id .. "/read", nil, callback)
end

function M.delete(client, notification_id, callback)
	http_mod.delete(client, "/api/v1/notifications/" .. notification_id, callback)
end

return M
