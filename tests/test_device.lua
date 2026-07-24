-- Unit test for the opt-in guest device-credential helper (asobi.device) and
-- the auth.guest_device convenience.
--
-- Pure Lua 5.4 - Defold's `sys` is stubbed (saved_store) so persistence is
-- exercised without the engine. The real guest() HTTP path is covered by
-- test_auth; here we monkeypatch auth.guest to assert the credentials the
-- helper generates/loads and forwards.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

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

-- --------------------------------------------------------------------
-- Standard-base64 decoder, to prove the generated secret is well-formed and
-- decodes to the byte length the server requires (>= 32).
-- --------------------------------------------------------------------
local function b64_decode(s)
	local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lookup = {}
	for i = 1, #B64 do lookup[B64:sub(i, i)] = i - 1 end
	local bytes = {}
	local acc, nbits = 0, 0
	for i = 1, #s do
		local c = s:sub(i, i)
		if c == "=" then break end
		local v = lookup[c]
		if not v then return nil end
		acc = acc * 64 + v
		nbits = nbits + 6
		if nbits >= 8 then
			nbits = nbits - 8
			local byte = math.floor(acc / (2 ^ nbits)) % 256
			bytes[#bytes + 1] = byte
			acc = acc % (2 ^ nbits) -- keep only the unconsumed low bits (bounds acc)
		end
	end
	return bytes
end

-- --------------------------------------------------------------------
local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok: " .. msg)
	else
		failures = failures + 1
		print("  FAIL: " .. msg)
	end
end

local function reset() saved_store = {} end

local device = require("asobi.device")

-- --------------------------------------------------------------------
print("base64 encoder golden vectors")
do
	-- RFC 4648 + edge cases: high bits (0xFF), both alphabet extremes (+ and /),
	-- and both tail-padding lengths. Locks the encoder against a silent break
	-- that a length-only check would miss.
	check(device._base64("") == "", "empty -> empty")
	check(device._base64("foobar") == "Zm9vYmFy", "RFC 4648: foobar")
	check(device._base64("\255\255\255") == "////", "3x 0xFF -> //// (no padding)")
	check(device._base64("\255\255") == "//8=", "2-byte tail -> one '=' pad")
	check(device._base64("\255") == "/w==", "1-byte tail -> two '=' pad")
	check(device._base64("\251\255") == "+/8=", "hits both '+' and '/'")
	check(device._base64("\0\0\0") == "AAAA", "zero bytes -> AAAA")
end

print("generate produces well-formed credentials")
do
	reset()
	local id, secret = device.generate()
	check(type(id) == "string" and id ~= "", "device_id is a non-empty string")
	check(type(secret) == "string" and secret ~= "", "device_secret is a non-empty string")
	local sbytes = b64_decode(secret)
	check(sbytes ~= nil, "device_secret is valid standard base64")
	check(sbytes and #sbytes == 32, "device_secret decodes to 32 bytes (>= server minimum)")
	local ibytes = b64_decode(id)
	check(ibytes ~= nil and #ibytes == 16, "device_id decodes to 16 bytes")
end

print("generate respects a custom random_bytes source")
do
	local fixed = string.rep("A", 32) -- 0x41 * 32
	local _, secret = device.generate({ random_bytes = function(n) return fixed:sub(1, n) end })
	local bytes = b64_decode(secret)
	check(bytes and #bytes == 32, "custom-sourced secret still decodes to 32 bytes")
	local all_a = true
	for _, b in ipairs(bytes or {}) do if b ~= 0x41 then all_a = false end end
	check(all_a, "custom bytes flow through unchanged (all 0x41)")
end

print("generate honours an explicit device_id")
do
	local id, _ = device.generate({ device_id = "my-stable-id" })
	check(id == "my-stable-id", "explicit device_id is used verbatim")
end

print("load_or_create persists and resumes the same pair")
do
	reset()
	local id1, secret1 = device.load_or_create()
	check(next(saved_store) ~= nil, "first call persisted a pair")
	local id2, secret2 = device.load_or_create()
	check(id1 == id2 and secret1 == secret2, "second call returns the SAME persisted pair")
end

print("load_or_create regenerates when the store is empty or invalid")
do
	reset()
	saved_store["asobi/guest_device"] = { device_id = "only-id" } -- missing secret
	local _, secret = device.load_or_create()
	check(secret ~= nil and secret ~= "", "regenerated a secret when the stored pair was invalid")
	check(b64_decode(secret) and #b64_decode(secret) == 32, "regenerated secret is well-formed")
end

print("load_or_create honours app/file overrides")
do
	reset()
	device.load_or_create({ app = "mygame", file = "creds" })
	check(saved_store["mygame/creds"] ~= nil, "persisted under the overridden app/file path")
end

print("clear erases stored credentials -> next load mints a fresh guest")
do
	reset()
	local id1 = select(1, device.load_or_create())
	device.clear()
	local stored = saved_store["asobi/guest_device"]
	check(type(stored) ~= "table" or not stored.device_secret, "cleared pair gone from storage")
	local id2 = select(1, device.load_or_create())
	check(id1 ~= id2, "a new guest id is minted after clear")
end

print("clear honours app/file overrides")
do
	reset()
	device.load_or_create({ app = "x", file = "y" })
	device.clear({ app = "x", file = "y" })
	local s = saved_store["x/y"]
	check(type(s) ~= "table" or not s.device_secret, "cleared under the overridden path")
end

-- --------------------------------------------------------------------
print("auth.guest_device loads/persists creds and forwards to guest")
do
	reset()
	local auth = require("asobi.api.auth")
	local real_guest = auth.guest
	local captured
	auth.guest = function(_client, id, secret, cb)
		captured = { id = id, secret = secret }
		cb({ player_id = "p1", created = true }, nil)
	end

	local got
	auth.guest_device({}, function(data, err) got = { data = data, err = err } end)

	check(captured ~= nil, "guest_device called guest")
	check(captured and b64_decode(captured.secret) and #b64_decode(captured.secret) == 32,
		"forwarded a well-formed 32-byte secret")
	check(got and got.data and got.data.player_id == "p1", "callback received the guest data")

	-- A second call must reuse the SAME persisted credentials.
	local first = captured
	auth.guest_device({}, function() end)
	check(captured.id == first.id and captured.secret == first.secret,
		"second guest_device reuses the persisted pair")

	auth.guest = real_guest
end

print("auth.guest_device forwards opts (app/file) to persistence")
do
	reset()
	local auth = require("asobi.api.auth")
	local real_guest = auth.guest
	auth.guest = function(_client, _id, _secret, cb) cb({ player_id = "p" }, nil) end

	auth.guest_device({}, { app = "mygame", file = "creds" }, function() end)
	check(saved_store["mygame/creds"] ~= nil, "opts routed through guest_device to load_or_create")

	auth.guest = real_guest
end

-- --------------------------------------------------------------------
if failures == 0 then
	print("OK: all device-helper tests passed")
	os.exit(0)
else
	print("FAILED: " .. failures .. " check(s)")
	os.exit(1)
end
