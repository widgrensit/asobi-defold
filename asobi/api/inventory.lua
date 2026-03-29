local http_mod = require("asobi.http")

local M = {}

function M.list(client, callback)
	http_mod.get(client, "/api/v1/inventory", nil, callback)
end

function M.consume(client, item_id, quantity, callback)
	http_mod.post(client, "/api/v1/inventory/consume",
		{item_id = item_id, quantity = quantity or 1}, callback)
end

return M
