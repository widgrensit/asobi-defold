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

function M.create(host, port, use_ssl)
	port = port or 8080
	use_ssl = use_ssl or false

	local scheme = use_ssl and "https" or "http"
	local ws_scheme = use_ssl and "wss" or "ws"

	local client = {
		host = host,
		port = port,
		use_ssl = use_ssl,
		base_url = scheme .. "://" .. host .. ":" .. tostring(port),
		ws_url = ws_scheme .. "://" .. host .. ":" .. tostring(port) .. "/ws",
		session_token = nil,
		player_id = nil,
	}

	client.http = http_mod
	client.realtime = realtime_mod
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

	realtime_mod.init(client)

	return client
end

return M
