-- The RPC seam: an extension's method, called over the same socket and
-- correlated by cid.
--
-- Pure unit test - no network, no Defold engine. Runs in plain Lua 5.4.
--
--   lua5.4 tests/test_rpc.lua

package.path = package.path .. ";./?.lua;./asobi/?.lua"

local FIXTURE_DIR = "tests/fixtures"
local json_decode = dofile("tests/json_decode.lua")

-- Defold stubs: realtime.lua references these as module-scope globals.
_G.websocket = {connect = function() return {} end, send = function() end,
	disconnect = function() end, EVENT_CONNECTED = 1, EVENT_DISCONNECTED = 2,
	EVENT_MESSAGE = 3, EVENT_ERROR = 4, DATA_TYPE_TEXT = "text"}
_G.http = {request = function() end}
_G.hash = function(s) return s end
_G.socket = {gettime = function() return 0 end}

-- Capture what would go out. Encoding is stubbed to hand back the table it was
-- given rather than a string, so a test can read the cid the SDK actually
-- chose instead of guessing one - the whole point of cid correlation is that
-- the SDK owns it.
local sent = {}
_G.json = {
	decode = json_decode,
	encode = function(t) sent[#sent + 1] = t; return "<encoded>" end,
}

local realtime = require("asobi.realtime")

local passed, failed = 0, 0
local function pass(what) passed = passed + 1; print("[rpc] PASS: " .. what) end
local function fail(what) failed = failed + 1; print("[rpc] FAIL: " .. what) end
local function check(what, got, want)
	if got == want then pass(what) else
		fail(what .. " - got " .. tostring(got) .. ", want " .. tostring(want))
	end
end

local function new_rt()
	sent = {}
	local rt = realtime.new({ws_url = "ws://stub", access_token = ""})
	-- _send_with_callback refuses to send without one, and short-circuits the
	-- callback with "not connected" instead.
	rt.connection = {}
	return rt, sent
end

local function feed(rt, msg)
	-- decode is stubbed to json_decode, so hand _handle_message something it
	-- will parse back into exactly this table.
	local prev = _G.json.decode
	_G.json.decode = function() return msg end
	rt:_handle_message("{}")
	_G.json.decode = prev
end

local function read_fixture(name)
	local f = assert(io.open(FIXTURE_DIR .. "/" .. name, "r"))
	local raw = f:read("*a")
	f:close()
	return json_decode(raw)
end

-- The envelope: `protocol` versions the payload rather than the frame type, so
-- a future version is a rejection a client can read.
do
	local rt = new_rt()
	rt:rpc("quests.claim", {quest_key = "daily"}, function() end)
	check("sends rpc.call", sent[1].type, "rpc.call")
	check("versions the payload", sent[1].payload.protocol, 1)
	check("carries the method", sent[1].payload.method, "quests.claim")
	check("carries the params", sent[1].payload.params.quest_key, "daily")
	check("mints a cid", type(sent[1].cid), "string")
end

do
	local rt = new_rt()
	rt:rpc("quests.list", nil, function() end)
	check("nil params is still an object", type(sent[1].payload.params), "table")
end

do
	local rt = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(result, err) got = {result, err} end)
	feed(rt, {type = "rpc.ok", cid = sent[1].cid, payload = {result = {reward = 100}}})
	check("rpc.ok resolves with the result", got[1].reward, 100)
	check("rpc.ok reports no error", got[2], nil)
end

-- The code is the only part of the shared error object a caller can branch on.
do
	local rt = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(result, err) got = {result, err} end)
	feed(rt, {
		type = "rpc.error",
		cid = sent[1].cid,
		payload = {error = {
			code = "quests.already_claimed",
			message = "This quest was already claimed.",
			details = {quest_key = "daily"},
		}},
	})
	check("rpc.error resolves with no result", got[1], nil)
	check("rpc.error carries the code", got[2].code, "quests.already_claimed")
	check("rpc.error carries the details", got[2].details.quest_key, "daily")
end

-- Otherwise a server defect and a domain outcome look identical to a caller
-- branching on `code`.
do
	local rt = new_rt()
	local got
	rt:rpc("quests.claim", {}, function(_, err) got = err end)
	feed(rt, {type = "rpc.error", cid = sent[1].cid, payload = {}})
	check("an empty error object still carries a code", got.code, "internal")
end

do
	local rt = new_rt()
	local first, second
	rt:rpc("quests.list", {}, function(r) first = r end)
	rt:rpc("quests.claim", {}, function(r) second = r end)
	check("two calls get different cids", sent[1].cid ~= sent[2].cid, true)
	-- Out of order: the second call answers first.
	feed(rt, {type = "rpc.ok", cid = sent[2].cid, payload = {result = {n = 2}}})
	feed(rt, {type = "rpc.ok", cid = sent[1].cid, payload = {result = {n = 1}}})
	check("the second call gets its own reply", second.n, 2)
	check("the first call gets its own reply", first.n, 1)
end

do
	local rt = new_rt()
	local calls = 0
	rt:rpc("quests.list", {}, function() calls = calls + 1 end)
	local reply = {type = "rpc.ok", cid = sent[1].cid, payload = {result = {}}}
	feed(rt, reply)
	feed(rt, reply)
	check("a duplicate reply does not call back twice", calls, 1)
end

-- Without a connection the callback must still fire, or a game that calls rpc
-- before connecting waits forever on a reply that was never sent.
do
	local rt = new_rt()
	rt.connection = nil
	local err
	rt:rpc("quests.list", {}, function(_, e) err = e end)
	check("an unconnected call reports rather than hangs", err, "not connected")
	check("and nothing went out", #sent, 0)
end

-- The fixtures are the shared corpus every SDK is checked against, so a server
-- change to the wire shape breaks this here rather than in a shipped game.
do
	local ok_fixture = read_fixture("rpc.ok.json")
	local err_fixture = read_fixture("rpc.error.json")

	local rt = new_rt()
	local got
	rt:rpc("anything", {}, function(result) got = result end)
	ok_fixture.cid = sent[1].cid
	feed(rt, ok_fixture)
	check("rpc.ok.json reaches the caller", got.reward, ok_fixture.payload.result.reward)

	local rt2 = new_rt()
	local err
	rt2:rpc("anything", {}, function(_, e) err = e end)
	err_fixture.cid = sent[1].cid
	feed(rt2, err_fixture)
	check("rpc.error.json reaches the caller", err.code, err_fixture.payload.error.code)
end

print(string.format("[rpc] %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)
