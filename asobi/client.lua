local http_mod = require("asobi.http")
local realtime_mod = require("asobi.realtime")
local auth = require("asobi.api.auth")
local players = require("asobi.api.players")
local matchmaker = require("asobi.api.matchmaker")
local matches = require("asobi.api.matches")
local leaderboards = require("asobi.api.leaderboards")
local economy = require("asobi.api.economy")
local inventory = require("asobi.api.inventory")
local social = require("asobi.api.social")
local tournaments = require("asobi.api.tournaments")
local notifications = require("asobi.api.notifications")
local storage = require("asobi.api.storage")
local iap = require("asobi.api.iap")
local votes = require("asobi.api.votes")
local worlds = require("asobi.api.worlds")
local dm = require("asobi.api.dm")

local M = {}

local SAVE_FILE = "auth"

-- refresh_token is long-lived and must survive app restarts, so it is
-- persisted via Defold's sys.save/sys.load. The access_token is kept in
-- memory only. Guarded so the module still loads outside the engine
-- (unit tests without a `sys` stub).
local function refresh_token_path()
	if not sys then return nil end
	return sys.get_save_file("asobi", SAVE_FILE)
end

local function load_refresh_token()
	local path = refresh_token_path()
	if not path then return nil end
	local data = sys.load(path)
	if data and data.refresh_token and data.refresh_token ~= "" then
		return data.refresh_token
	end
	return nil
end

local function persist_refresh_token(token)
	local path = refresh_token_path()
	if not path then return end
	sys.save(path, {refresh_token = token or ""})
end

-- Drop the explicit port when it matches the scheme default. Some WS
-- clients (notably Defold's extension-websocket) fail to connect to
-- wss://host:443/path even though the URL is technically valid.
local function authority(host, port, default_port)
	if port == default_port then
		return host
	end
	return host .. ":" .. tostring(port)
end

function M.create(host, port, use_ssl)
	port = port or 8084
	use_ssl = use_ssl or false

	local scheme = use_ssl and "https" or "http"
	local ws_scheme = use_ssl and "wss" or "ws"
	local http_default = use_ssl and 443 or 80
	local ws_default = use_ssl and 443 or 80

	local client = {
		host = host,
		port = port,
		use_ssl = use_ssl,
		base_url = scheme .. "://" .. authority(host, port, http_default),
		ws_url = ws_scheme .. "://" .. authority(host, port, ws_default) .. "/ws",
		access_token = nil,
		refresh_token = load_refresh_token(),
		player_id = nil,
	}

	function client.set_tokens(access_token, refresh_token)
		client.access_token = access_token
		client.refresh_token = refresh_token
		persist_refresh_token(refresh_token)
	end

	function client.clear_tokens()
		client.access_token = nil
		client.refresh_token = nil
		persist_refresh_token(nil)
	end

	client.http = http_mod
	client.auth = auth
	client.players = players
	client.matchmaker = matchmaker
	client.matches = matches
	client.leaderboards = leaderboards
	client.economy = economy
	client.inventory = inventory
	client.social = social
	client.tournaments = tournaments
	client.notifications = notifications
	client.storage = storage
	client.iap = iap
	client.votes = votes
	client.worlds = worlds
	client.dm = dm

	client.realtime = realtime_mod.new(client)

	return client
end

return M
