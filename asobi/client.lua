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
		session_token = nil,
		player_id = nil,
	}

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
