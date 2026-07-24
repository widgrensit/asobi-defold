-- Unit test for http response handling, focused on the non-JSON-body guard:
-- a gateway/proxy error ("no available server" during a redeploy) must surface
-- a clean error to the callback, not throw an opaque json.decode crash.

package.path = package.path .. ";./?.lua;./asobi/?.lua"

-- Minimal json stub that raises on invalid input, like Defold's json.decode.
_G.json = {
	decode = function(s)
		local first = s:sub(1, 1)
		if first == "{" or first == "[" then
			-- Good enough for these tests: return a fixed decoded shape.
			if s:find('"error"') then
				return { error = "guest_auth_disabled" }
			end
			return { player_id = "p1", created = true }
		end
		error("Expected value but found invalid token at character 1")
	end,
	encode = function(_)
		return "{}"
	end,
}

local http = require("asobi.http")

local failures = 0
local function check(cond, msg)
	if cond then
		print("  ok: " .. msg)
	else
		failures = failures + 1
		print("  FAIL: " .. msg)
	end
end

print("non-JSON body -> clean invalid_response error, no crash")
do
	local got
	local ok = pcall(function()
		http._handle_response({ status = 503, response = "no available server" }, function(data, err)
			got = { data = data, err = err }
		end)
	end)
	check(ok, "_handle_response did not throw on a non-JSON body")
	check(got and got.err ~= nil and got.data == nil, "callback got an error, not data")
	check(got and got.err.error == "invalid_response", "error code is invalid_response")
	check(got and got.err.status_code == 503, "status_code preserved")
	check(got and got.err.raw == "no available server", "raw body snippet included")
end

print("oversized non-JSON body -> raw is truncated to 200 chars")
do
	local got
	local big = string.rep("x", 500) -- not JSON, >200 chars
	http._handle_response({ status = 502, response = big }, function(data, err)
		got = { data = data, err = err }
	end)
	check(got and got.err and got.err.error == "invalid_response", "still a clean error")
	check(got and got.err.raw and #got.err.raw == 200, "raw truncated to 200 chars")
end

print("valid JSON success -> body passed through")
do
	local got
	http._handle_response({ status = 200, response = '{"player_id":"p1"}' }, function(data, err)
		got = { data = data, err = err }
	end)
	check(got and got.err == nil and got.data ~= nil, "success callback got data")
	check(got.data.player_id == "p1", "decoded body reached the callback")
end

print("JSON error status -> error propagated")
do
	local got
	http._handle_response({ status = 403, response = '{"error":"guest_auth_disabled"}' }, function(data, err)
		got = { data = data, err = err }
	end)
	check(got and got.err ~= nil, "error callback fired")
	check(got.err.error == "guest_auth_disabled", "app error code propagated")
	check(got.err.status_code == 403, "status_code propagated")
end

print("empty body -> treated as empty, no decode")
do
	local got
	http._handle_response({ status = 200, response = "" }, function(data, err)
		got = { data = data, err = err }
	end)
	check(got and got.err == nil, "empty body is a success no-op")
end

if failures == 0 then
	print("OK: all http-handler tests passed")
	os.exit(0)
else
	print("FAILED: " .. failures .. " check(s)")
	os.exit(1)
end
