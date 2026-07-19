-- Dispatch unit test: feeds every canonical fixture through the SDK's
-- realtime message handler and asserts the right callback fires.
--
-- Pure unit test — no network, no Defold engine. Runs in plain Lua 5.4.
-- Catches the doc-vs-server drift class of bugs (e.g. server emits
-- match.matched but SDK only listens for matchmaker.matched) before any
-- user reports a silent failure.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

local FIXTURE_DIR = "tests/fixtures"

-- Defold stubs: realtime.lua references these as module-scope globals.
_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end

-- Minimal JSON decoder — enough for the canonical fixture corpus.
-- (Defold ships with a `json` module; outside the engine we provide
-- our own so the test stays dependency-free.)
local json_decode
do
	local pos
	local skip_ws = function(s)
		while pos <= #s do
			local c = s:byte(pos)
			if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
		end
	end
	local parse
	local function parse_string(s)
		assert(s:sub(pos, pos) == '"', "expected '\"' at " .. pos)
		pos = pos + 1
		local out = {}
		while pos <= #s do
			local c = s:sub(pos, pos)
			if c == '"' then pos = pos + 1; return table.concat(out)
			elseif c == "\\" then
				local n = s:sub(pos + 1, pos + 1)
				if n == "n" then out[#out + 1] = "\n"
				elseif n == "t" then out[#out + 1] = "\t"
				elseif n == "r" then out[#out + 1] = "\r"
				elseif n == '"' then out[#out + 1] = '"'
				elseif n == "\\" then out[#out + 1] = "\\"
				elseif n == "/" then out[#out + 1] = "/"
				else out[#out + 1] = n end
				pos = pos + 2
			else
				out[#out + 1] = c
				pos = pos + 1
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
		if s:sub(pos, pos + #lit - 1) == lit then pos = pos + #lit; return val end
		error("bad literal at " .. pos)
	end
	local function parse_object(s)
		assert(s:sub(pos, pos) == "{")
		pos = pos + 1
		local out = {}
		skip_ws(s)
		if s:sub(pos, pos) == "}" then pos = pos + 1; return out end
		while true do
			skip_ws(s)
			local k = parse_string(s)
			skip_ws(s)
			assert(s:sub(pos, pos) == ":", "expected ':'")
			pos = pos + 1
			skip_ws(s)
			out[k] = parse(s)
			skip_ws(s)
			local c = s:sub(pos, pos)
			if c == "," then pos = pos + 1
			elseif c == "}" then pos = pos + 1; return out
			else error("bad object at " .. pos) end
		end
	end
	local function parse_array(s)
		assert(s:sub(pos, pos) == "[")
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
	json_decode = function(s) pos = 1; return parse(s) end
end

_G.json = {encode = function() return "" end, decode = json_decode}

-- For each server wire `type`, the SDK callback name a user binds via
-- realtime.on(...). Mirrors the dispatch table in asobi/realtime.lua.
-- Drift between this map and the SDK is caught by the assertions below.
local EXPECTED = {
	["error"] = "error",
	["session.connected"] = "connected",
	["session.heartbeat"] = "heartbeat",
	["match.state"] = "match_state",
	["match.matched"] = "match_matched",
	["match.joined"] = "match_joined",
	["match.left"] = "match_left",
	["match.finished"] = "match_finished",
	["match.matchmaker_expired"] = "matchmaker_expired",
	["match.matchmaker_failed"] = "matchmaker_failed",
	["match.vote_start"] = "vote_start",
	["match.vote_tally"] = "vote_tally",
	["match.list"] = "match_list",
	["match.vote_result"] = "vote_result",
	["match.vote_vetoed"] = "vote_vetoed",
	["matchmaker.queued"] = "matchmaker_queued",
	["matchmaker.removed"] = "matchmaker_removed",
	["chat.joined"] = "chat_joined",
	["chat.left"] = "chat_left",
	["chat.message"] = "chat_message",
	["dm.sent"] = "dm_sent",
	["dm.message"] = "dm_message",
	["presence.updated"] = "presence_changed",
	["notification.new"] = "notification",
	["vote.cast_ok"] = "vote_cast_ok",
	["vote.veto_ok"] = "vote_veto_ok",
	["world.tick"] = "world_tick",
	["world.terrain"] = "world_terrain",
	["world.list"] = "world_list",
	["world.joined"] = "world_joined",
	["world.left"] = "world_left",
	["world.phase_changed"] = "phase_changed",
	["world.finished"] = "world_finished",
}

local fail_count = 0
local pass_count = 0

local function fail(msg)
	print("[dispatch] FAIL: " .. msg)
	fail_count = fail_count + 1
end

local function pass(msg)
	pass_count = pass_count + 1
	print("[dispatch] PASS: " .. msg)
end

local function list_fixtures()
	local out = {}
	local p = io.popen('ls "' .. FIXTURE_DIR .. '"')
	if not p then return out end
	for line in p:lines() do
		if line:match("%.json$") then table.insert(out, line) end
	end
	p:close()
	table.sort(out)
	return out
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Realtime is per-instance; spin up a fresh one per fixture so callbacks
-- and entity registries don't leak between assertions.
local realtime = require("asobi.realtime")

local function new_rt()
	return realtime.new({ws_url = "ws://stub", access_token = ""})
end

local fixtures = list_fixtures()
if #fixtures == 0 then fail("no fixtures found in " .. FIXTURE_DIR) end

local fixture_types = {}
for _, name in ipairs(fixtures) do fixture_types[name:gsub("%.json$", "")] = true end

for _, name in ipairs(fixtures) do
	local mtype = name:gsub("%.json$", "")
	if not EXPECTED[mtype] then
		fail("fixture '" .. name .. "' has no entry in EXPECTED — add a SDK callback mapping")
	end
end

for mtype, _ in pairs(EXPECTED) do
	if not fixture_types[mtype] then
		fail("EXPECTED maps '" .. mtype .. "' but no fixture exists — stale or fixture missing")
	end
end

for _, name in ipairs(fixtures) do
	local mtype = name:gsub("%.json$", "")
	local expected_cb = EXPECTED[mtype]
	if expected_cb then
		local raw = read_file(FIXTURE_DIR .. "/" .. name)
		if not raw then
			fail("could not read " .. name)
		else
			local rt = new_rt()
			local fired = false
			rt:on(expected_cb, function(_payload) fired = true end)
			rt:_handle_message(raw)
			if fired then
				pass(mtype .. " -> on(" .. expected_cb .. ")")
			else
				fail(mtype .. " did not fire on(" .. expected_cb .. ")")
			end
		end
	end
end

print(string.format("[dispatch] %d passed, %d failed (%d fixtures)",
	pass_count, fail_count, #fixtures))
if fail_count > 0 then os.exit(1) end
