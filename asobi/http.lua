local M = {}

function M.get(client, path, query, callback)
	local url = M._build_url(client, path, query)
	http.request(url, "GET", function(self, id, response)
		M._handle_response(response, callback)
	end, M._headers(client))
end

function M.post(client, path, body, callback)
	local url = M._build_url(client, path)
	local data = body and json.encode(body) or ""
	http.request(url, "POST", function(self, id, response)
		M._handle_response(response, callback)
	end, M._headers(client), data)
end

function M.put(client, path, body, callback)
	local url = M._build_url(client, path)
	local data = body and json.encode(body) or ""
	http.request(url, "PUT", function(self, id, response)
		M._handle_response(response, callback)
	end, M._headers(client), data)
end

function M.delete(client, path, callback)
	local url = M._build_url(client, path)
	http.request(url, "DELETE", function(self, id, response)
		M._handle_response(response, callback)
	end, M._headers(client))
end

function M._headers(client)
	local h = {["Content-Type"] = "application/json"}
	if client.session_token and client.session_token ~= "" then
		h["Authorization"] = "Bearer " .. client.session_token
	end
	return h
end

function M._build_url(client, path, query)
	local url = client.base_url .. path
	if query then
		local parts = {}
		for k, v in pairs(query) do
			table.insert(parts, k .. "=" .. tostring(v))
		end
		if #parts > 0 then
			url = url .. "?" .. table.concat(parts, "&")
		end
	end
	return url
end

function M._handle_response(response, callback)
	if not callback then return end
	local body = {}
	if response.response and response.response ~= "" then
		body = json.decode(response.response)
	end
	if response.status >= 400 then
		callback(nil, {
			status_code = response.status,
			error = body and body.error or ("HTTP " .. response.status)
		})
	else
		callback(body, nil)
	end
end

return M
