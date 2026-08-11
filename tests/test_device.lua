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
-- Regression cases for the HTML5 shared-guest bug. Two independent defects:
-- the seed was ~200x INT32_MAX and saturated to a constant under wasm (Lua 5.1
-- narrows it via srand((int)x)), and the colliding pair was then persisted, so
-- affected installs keep resuming the one shared guest until they re-mint.
-- The module memoises "the RNG is seeded", so each case needs fresh state.
-- --------------------------------------------------------------------
local function fresh_device(html5_run)
	package.loaded["asobi.device"] = nil
	_G.html5 = html5_run and { run = html5_run } or nil
	return require("asobi.device")
end

print("web build sources bytes from crypto.getRandomValues")
do
	local asked
	local d = fresh_device(function(js)
		asked = js
		-- Stand in for the browser: 0x00..0x(n-1) as a hex string.
		local n = tonumber(js:match("Uint8Array%((%d+)%)"))
		local hex = {}
		for i = 1, n do hex[i] = string.format("%02x", (i - 1) % 256) end
		return table.concat(hex)
	end)
	local _, secret = d.generate()
	check(asked ~= nil and asked:find("getRandomValues", 1, true) ~= nil,
		"generate called crypto.getRandomValues via html5.run")
	check(asked ~= nil and asked:find("catch", 1, true) ~= nil,
		"injected JS catches its own errors instead of throwing into Lua")
	local bytes = b64_decode(secret)
	check(bytes and #bytes == 32, "browser-sourced secret decodes to 32 bytes")
	local from_crypto = bytes and bytes[1] == 0 and bytes[2] == 1 and bytes[3] == 2
	check(from_crypto, "secret bytes came from the browser CSPRNG, not math.random")
end

-- On web the seeded RNG is NOT an acceptable fallback (it degrades to
-- whole-second granularity under wasm), so every unusable browser response
-- must raise rather than quietly mint a weak credential. `print` is compiled
-- out of Defold release bundles, so a warning here would be invisible on the
-- platform it targets - matching asobi-js, which throws.
local BAD_CRYPTO_RESPONSES = {
	["html5.run raised"] = function() error("no crypto in this context") end,
	["a garbage string"] = function() return "not-hex" end,
	["well-formed hex of the wrong length"] = function() return string.rep("ab", 16) end,
	["an empty string (the JS catch path)"] = function() return "" end,
	["a non-string"] = function() return 42 end,
	["hex that would crash string.char"] = function(js)
		local n = tonumber(js:match("Uint8Array%((%d+)%)"))
		return "-1" .. string.rep("ff", n - 1) -- tonumber("-1", 16) == -1
	end,
}

print("web build raises rather than degrading to the seeded RNG")
do
	for label, run in pairs(BAD_CRYPTO_RESPONSES) do
		local d = fresh_device(run)
		local ok, err = pcall(d.generate)
		check(not ok, "raised on " .. label)
		check(not ok and tostring(err):find("Web Crypto", 1, true) ~= nil,
			"error names the cause for " .. label .. ": " .. tostring(err))
	end
end

print("opts.random_bytes rescues a browser with no Web Crypto")
do
	local d = fresh_device(function() return "" end)
	local fixed = string.rep("A", 32)
	local ok, _, secret = pcall(function()
		return d.generate({ random_bytes = function(n) return fixed:sub(1, n) end })
	end)
	check(ok, "an explicit source is used without ever touching html5.run")
	check(ok and secret ~= nil, "and still returns a secret")
end

print("an explicit random_bytes source still wins over the browser CSPRNG")
do
	local d = fresh_device(function() return string.rep("ff", 64) end)
	local fixed = string.rep("A", 32)
	local _, secret = d.generate({ random_bytes = function(n) return fixed:sub(1, n) end })
	local bytes = b64_decode(secret)
	local all_a = bytes ~= nil
	for _, b in ipairs(bytes or {}) do if b ~= 0x41 then all_a = false end end
	check(all_a, "opts.random_bytes is not overridden by the html5 path")
end

-- Stubs the real boundary rather than an exposed helper, so the check fails if
-- the seed stops being clamped OR if the clamping stops being on the path
-- generate() actually takes.
print("the native seeded path seeds inside int32")
do
	local d = fresh_device(nil)
	local captured
	local real_seed = math.randomseed
	-- luacheck: push ignore 122
	math.randomseed = function(s) captured = s; return real_seed(s) end
	d.generate()
	math.randomseed = real_seed
	-- luacheck: pop
	check(captured ~= nil, "default_random_bytes seeded the RNG")
	check(captured ~= nil and captured == math.floor(captured), "the seed is an integer")
	check(captured ~= nil and captured >= 0 and captured <= 2147483647,
		"the seed it passed survives srand((int)x) (got " .. tostring(captured) .. ")")
end

-- The bug's real persistence: an affected browser has the shared pair in
-- IndexedDB, and without this it would resume that guest forever.
print("a stored pre-fix pair is discarded on web so the install re-mints")
do
	reset()
	local shared = { device_id = "the-shared-one", device_secret = "old-secret" }
	saved_store["asobi/guest_device"] = shared

	local web = fresh_device(function(js)
		local n = tonumber(js:match("Uint8Array%((%d+)%)"))
		return string.rep("7f", n)
	end)
	local id = select(1, web.load_or_create())
	check(id ~= "the-shared-one", "unversioned pair rejected on web, a fresh id was minted")
	check(saved_store["asobi/guest_device"].version ~= nil, "the replacement is versioned")

	-- Same stored blob, native: that install was never affected and must keep
	-- its account rather than being silently logged out.
	saved_store["asobi/guest_device"] = shared
	local native = fresh_device(nil)
	check(select(1, native.load_or_create()) == "the-shared-one",
		"the same unversioned pair is still honoured off web")
end

print("a versioned pair resumes normally on web")
do
	reset()
	local web = fresh_device(function(js)
		local n = tonumber(js:match("Uint8Array%((%d+)%)"))
		return string.rep("7f", n)
	end)
	local id1, secret1 = web.load_or_create()
	local id2, secret2 = web.load_or_create()
	check(id1 == id2 and secret1 == secret2, "second load resumes the pair it just minted")
end

-- Restore the plain, non-web module for the remaining cases.
package.loaded["asobi.device"] = nil
_G.html5 = nil

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
