-- Auth-flow unit test for the access_token + refresh_token pair.
--
-- Pure Lua 5.4 — Defold's http/websocket/json/sys are stubbed so the SDK
-- loads outside the engine. The http.request stub answers synchronously
-- from a scripted response queue, so callback chains resolve inline.
--
-- Covers: token-pair parse on register/login, single-use refresh rotation,
-- 401-refresh-retry (success + exhaustion), logout, WS access_token send.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

-- --------------------------------------------------------------------
-- Minimal JSON encode/decode (flat objects + arrays of scalars).
-- --------------------------------------------------------------------
local json = {}

function json.encode(v)
	local t = type(v)
	if t == "string" then
		return '"' .. v:gsub('[\\"]', {["\\"] = "\\\\", ['"'] = '\\"'}) .. '"'
	elseif t == "number" then
		return tostring(v)
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "nil" then
		return "null"
	elseif t == "table" then
		local n, arrn = 0, #v
		for _ in pairs(v) do n = n + 1 end
		if arrn == n and arrn > 0 then
			local parts = {}
			for i = 1, arrn do parts[i] = json.encode(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = '"' .. tostring(k) .. '":' .. json.encode(val)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

do
	local pos
	local parse
	local function skip_ws(s)
		while pos <= #s do
			local c = s:byte(pos)
			if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
		end
	end
	local function parse_string(s)
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1; return table.concat(out)
			elseif c == "\\" then
				out[#out + 1] = s:sub(pos + 1, pos + 1); pos = pos + 2
			else
				out[#out + 1] = c; pos = pos + 1
			end
		end
		error("unterminated string")
	end
	local function parse_number(s)
		local start = pos
		while pos <= #s do
			local c = s:byte(pos)
			if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69 then
				pos = pos + 1
			else break end
		end
		return tonumber(s:sub(start, pos - 1))
	end
	local function parse_literal(s, lit, val)
		pos = pos + #lit; return val
	end
	local function parse_object(s)
		pos = pos + 1
		local out = {}
		skip_ws(s)
		if s:sub(pos, pos) == "}" then pos = pos + 1; return out end
		while true do
			skip_ws(s)
			local k = parse_string(s)
			skip_ws(s); pos = pos + 1; skip_ws(s)
			out[k] = parse(s)
			skip_ws(s)
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "}" then pos = pos + 1; return out
			else error("bad object at " .. pos) end
		end
	end
	local function parse_array(s)
		pos = pos + 1
		local out = {}
		skip_ws(s)
		if s:sub(pos, pos) == "]" then pos = pos + 1; return out end
		while true do
			skip_ws(s)
			out[#out + 1] = parse(s)
			skip_ws(s)
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "]" then pos = pos + 1; return out
			else error("bad array at " .. pos) end
		end
	end
	parse = function(s)
		skip_ws(s)
		local c = s:sub(pos, pos)
		if c == "{" then return parse_object(s)
		elseif c == "[" then return parse_array(s)
		elseif c == '"' then return parse_string(s)
		elseif c == "t" then return parse_literal(s, "true", true)
		elseif c == "f" then return parse_literal(s, "false", false)
		elseif c == "n" then return parse_literal(s, "null", nil)
		else return parse_number(s) end
	end
	json.decode = function(s) pos = 1; return parse(s) end
end

_G.json = json

-- --------------------------------------------------------------------
-- Defold stubs.
-- --------------------------------------------------------------------
local saved_store = {}
_G.sys = {
	get_save_file = function(app, file) return app .. "/" .. file end,
	save = function(path, tbl) saved_store[path] = tbl; return true end,
	load = function(path) return saved_store[path] or {} end,
}

_G.socket = {gettime = function() return 0 end}
_G.hash = function(s) return s end

local ws_last_send = nil
local ws_on_event = nil
_G.websocket = {
	connect = function(_url, _params, cb) ws_on_event = cb; return {} end,
	send = function(_conn, msg) ws_last_send = msg end,
	disconnect = function() end,
	EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2, EVENT_MESSAGE = 3, EVENT_ERROR = 4,
	DATA_TYPE_TEXT = "text",
}

-- http.request stub. Records every call and answers from a scripted
-- queue (FIFO). Callbacks fire synchronously so chains resolve inline.
local http_requests = {}
local http_responses = {}
_G.http = {
	request = function(url, method, cb, headers, data)
		table.insert(http_requests, {url = url, method = method, headers = headers, data = data})
		local resp = table.remove(http_responses, 1) or {status = 200, response = "{}"}
		cb(nil, 0, resp)
	end,
}

local function queue(status, body)
	table.insert(http_responses, {status = status, response = json.encode(body or {})})
end

local function reset()
	http_requests = {}
	http_responses = {}
	saved_store = {}
	ws_last_send = nil
	ws_on_event = nil
end

-- --------------------------------------------------------------------
local failures = 0
local function check(cond, msg)
	if not cond then
		print("FAIL: " .. msg)
		failures = failures + 1
	end
end

local asobi = require("asobi.client")

local function new_client()
	return asobi.create("localhost", 8084)
end

-- Test 1: register parses and stores the token pair + player_id.
do
	reset()
	local client = new_client()
	queue(200, {player_id = "p1", access_token = "A1", refresh_token = "R1", username = "u"})
	local got
	client.auth.register(client, "u", "pw", "u", function(data, err) got = {data = data, err = err} end)

	check(got and not got.err, "register callback fired without error")
	check(client.access_token == "A1", "register stored access_token")
	check(client.refresh_token == "R1", "register stored refresh_token")
	check(client.player_id == "p1", "register stored player_id")
	check(saved_store["asobi/auth"] and saved_store["asobi/auth"].refresh_token == "R1",
		"register persisted refresh_token via sys.save")
end

-- Test 2: login parses and stores the token pair.
do
	reset()
	local client = new_client()
	queue(200, {player_id = "p2", access_token = "LA", refresh_token = "LR", username = "u"})
	client.auth.login(client, "u", "pw", function() end)
	check(client.access_token == "LA" and client.refresh_token == "LR", "login stored token pair")
	check(client.player_id == "p2", "login stored player_id")
end

-- Test 3: refresh sends {refresh_token} and rotates BOTH tokens.
do
	reset()
	local client = new_client()
	client.set_tokens("A1", "R1")
	queue(200, {access_token = "A2", refresh_token = "R2"})
	client.auth.refresh(client, function() end)

	local body = json.decode(http_requests[1].data)
	check(body.refresh_token == "R1", "refresh posts the stored refresh_token")
	check(http_requests[1].url:find("/api/v1/auth/refresh", 1, true) ~= nil, "refresh hits /auth/refresh")
	check(client.access_token == "A2", "refresh rotated access_token")
	check(client.refresh_token == "R2", "refresh rotated refresh_token (single-use)")
	check(saved_store["asobi/auth"].refresh_token == "R2", "refresh persisted rotated refresh_token")
end

-- Test 4: a 401 on an authed call refreshes and retries ONCE with the
-- rotated access_token, then surfaces the retried success.
do
	reset()
	local client = new_client()
	client.set_tokens("A1", "R1")
	queue(401, {error = "invalid_token"})            -- original GET
	queue(200, {access_token = "A2", refresh_token = "R2"}) -- refresh
	queue(200, {ok = true})                          -- retried GET
	local got
	client.http.get(client, "/api/v1/players/me", nil, function(data, err) got = {data = data, err = err} end)

	check(#http_requests == 3, "401 path made 3 requests (original, refresh, retry)")
	check(http_requests[1].headers.Authorization == "Bearer A1", "original request used old access_token")
	check(http_requests[2].url:find("/auth/refresh", 1, true) ~= nil, "second request was the refresh")
	check(http_requests[3].headers.Authorization == "Bearer A2", "retry used the rotated access_token")
	check(got and not got.err and got.data.ok == true, "retried request surfaced success")
end

-- Test 5: refresh failure during the 401 path surfaces auth_expired and
-- does NOT retry the original request again.
do
	reset()
	local client = new_client()
	client.set_tokens("A1", "R1")
	queue(401, {error = "invalid_token"}) -- original GET
	queue(401, {error = "invalid_token"}) -- refresh fails
	local got
	client.http.get(client, "/api/v1/players/me", nil, function(data, err) got = {data = data, err = err} end)

	check(#http_requests == 2, "no retry when refresh fails")
	check(got and got.err and got.err.error == "auth_expired", "surfaces auth_expired on refresh failure")
end

-- Test 6: a 401 from an /auth/* call is NOT intercepted (no refresh loop).
do
	reset()
	local client = new_client()
	client.set_tokens("A1", "R1")
	queue(401, {error = "invalid_credentials"})
	local got
	client.auth.login(client, "u", "bad", function(data, err) got = {data = data, err = err} end)
	check(#http_requests == 1, "login 401 is not intercepted/retried")
	check(got and got.err and got.err.error == "invalid_credentials", "login 401 surfaced verbatim")
end

-- Test 7: logout posts {refresh_token} with Bearer, then clears + wipes tokens.
do
	reset()
	local client = new_client()
	client.set_tokens("A1", "R1")
	client.player_id = "p1"
	queue(200, {success = true})
	local got
	client.auth.logout(client, function(data, err) got = {data = data, err = err} end)

	local body = json.decode(http_requests[1].data)
	check(http_requests[1].url:find("/api/v1/auth/logout", 1, true) ~= nil, "logout hits /auth/logout")
	check(body.refresh_token == "R1", "logout sends refresh_token")
	check(http_requests[1].headers.Authorization == "Bearer A1", "logout sends Bearer access_token")
	check(client.access_token == nil and client.refresh_token == nil, "logout cleared in-memory tokens")
	check(client.player_id == nil, "logout cleared player_id")
	check(saved_store["asobi/auth"].refresh_token == "", "logout wiped persisted refresh_token")
	check(got and not got.err and got.data.success == true, "logout callback fired with success")
end

-- Test 8: refresh_token is loaded from persistence on client init.
do
	reset()
	saved_store["asobi/auth"] = {refresh_token = "PERSISTED"}
	local client = new_client()
	check(client.refresh_token == "PERSISTED", "client init loads persisted refresh_token")
	check(client.access_token == nil, "access_token starts nil (memory only)")
end

-- Test 9: WS session.connect sends the access_token; reauth re-sends it.
do
	reset()
	local client = new_client()
	client.set_tokens("WSTOKEN", "R1")
	client.realtime:connect()
	ws_on_event(nil, {}, {event = websocket.EVENT_CONNECTED})
	local sent = json.decode(ws_last_send)
	check(sent.type == "session.connect", "WS sends session.connect on connect")
	check(sent.payload.token == "WSTOKEN", "WS session.connect carries the access_token")

	client.set_tokens("ROTATED", "R2")
	ws_last_send = nil
	client.realtime:reauth()
	local reauth_sent = json.decode(ws_last_send)
	check(reauth_sent.payload.token == "ROTATED", "reauth re-sends the rotated access_token")
end

-- Test 10: auth-related socket errors surface as auth_expired.
do
	reset()
	local realtime = require("asobi.realtime")
	local rt = realtime.new({access_token = "A1"})
	local expired
	rt:on("auth_expired", function(reason) expired = reason end)
	rt:_handle_message(json.encode({type = "error", payload = {reason = "invalid_token"}}))
	check(expired == "invalid_token", "invalid_token error message fires auth_expired")

	check(realtime._is_auth_close("session_revoked") == true, "session_revoked close is auth-expired")
	check(realtime._is_auth_close("idle_auth_timeout") == true, "idle_auth_timeout close is auth-expired")
	check(realtime._is_auth_close("closed") == false, "ordinary close is not auth-expired")
end

-- Test 11: guest posts {device_id, device_secret} with no auth header and
-- stores the returned token pair + player_id.
do
	reset()
	local client = new_client()
	queue(200, {
		player_id = "g1", access_token = "GA", refresh_token = "GR",
		username = "guest-1", created = true, guest = true,
	})
	local got
	client.auth.guest(client, "device-abc", "c2VjcmV0", function(data, err) got = {data = data, err = err} end)

	local body = json.decode(http_requests[1].data)
	check(http_requests[1].url:find("/api/v1/auth/guest", 1, true) ~= nil, "guest hits /auth/guest")
	check(body.device_id == "device-abc", "guest posts device_id")
	check(body.device_secret == "c2VjcmV0", "guest posts device_secret")
	check(http_requests[1].headers.Authorization == nil, "guest sends no auth header")
	check(client.access_token == "GA" and client.refresh_token == "GR", "guest stored token pair")
	check(client.player_id == "g1", "guest stored player_id")
	check(saved_store["asobi/auth"].refresh_token == "GR", "guest persisted refresh_token")
	check(got and not got.err and got.data.created == true, "guest callback surfaced created:true")
end

-- Test 12: a guest error (e.g. weak_device_secret) surfaces verbatim and
-- leaves tokens untouched.
do
	reset()
	local client = new_client()
	queue(400, {error = "weak_device_secret"})
	local got
	client.auth.guest(client, "device-abc", "short", function(data, err) got = {data = data, err = err} end)
	check(got and got.err and got.err.error == "weak_device_secret", "guest error surfaced verbatim")
	check(client.access_token == nil and client.refresh_token == nil, "guest error left tokens untouched")
end

-- Test 13: upgrade_guest posts {username, password} with the current Bearer
-- token and REPLACES the stored token pair with the returned one.
do
	reset()
	local client = new_client()
	client.set_tokens("GA", "GR")
	client.player_id = "g1"
	queue(200, {player_id = "g1", access_token = "UA", refresh_token = "UR", username = "claimed", upgraded = true})
	local got
	client.auth.upgrade_guest(client, "claimed", "pass1234", function(data, err) got = {data = data, err = err} end)

	local body = json.decode(http_requests[1].data)
	check(http_requests[1].url:find("/api/v1/auth/guest/upgrade", 1, true) ~= nil, "upgrade hits /auth/guest/upgrade")
	check(body.username == "claimed" and body.password == "pass1234", "upgrade posts username + password")
	check(http_requests[1].headers.Authorization == "Bearer GA", "upgrade sends current Bearer access_token")
	check(client.access_token == "UA" and client.refresh_token == "UR", "upgrade replaced token pair")
	check(saved_store["asobi/auth"].refresh_token == "UR", "upgrade persisted replaced refresh_token")
	check(got and not got.err and got.data.upgraded == true, "upgrade callback surfaced upgraded:true")
end

-- Test 14: an upgrade conflict (username_taken) surfaces verbatim and leaves
-- the existing guest tokens in place.
do
	reset()
	local client = new_client()
	client.set_tokens("GA", "GR")
	queue(409, {error = "username_taken"})
	local got
	client.auth.upgrade_guest(client, "taken", "pass1234", function(data, err) got = {data = data, err = err} end)
	check(got and got.err and got.err.error == "username_taken", "upgrade conflict surfaced verbatim")
	check(client.access_token == "GA" and client.refresh_token == "GR", "upgrade error kept existing tokens")
end

-- --------------------------------------------------------------------
if failures == 0 then
	print("OK: all auth-flow tests passed")
	os.exit(0)
else
	print("FAIL: " .. failures .. " test(s) failed")
	os.exit(1)
end
