-- Event-name validation: registering a callback for a name the SDK never
-- fires is a silent failure — indistinguishable from the server not sending
-- the event. realtime.lua rejects unknown names at register time so the
-- error points at the offending line instead.
--
-- Pure unit test, plain Lua 5.4:
--   lua5.4 tests/test_event_names.lua

package.path = package.path .. ";./?.lua;./asobi/?.lua"

local realtime = require("asobi.realtime")

local failures = 0

local function check(cond, msg)
	if cond then
		print("  ok  " .. msg)
	else
		print("  FAIL " .. msg)
		failures = failures + 1
	end
end

local rt = realtime.new({})

-- Every name the SDK actually fires must be registerable.
for _, name in ipairs({
	"match_joined",
	"match_list",
	"connected",
	"disconnected",
	"auth_expired",
	"entity_added",
	"entity_updated",
	"entity_removed",
	"tick",
	"error",
	"world_terrain",
}) do
	local ok = pcall(function()
		rt:on(name, function() end)
	end)
	check(ok, name .. " is registerable")
end

-- A typo must fail loudly rather than register a callback that never fires.
local ok, err = pcall(function()
	rt:on("match.joined", function() end)
end)
check(not ok, "the wire name 'match.joined' is rejected (the callback is 'match_joined')")
check(
	ok == false and tostring(err):find("would never fire", 1, true) ~= nil,
	"the error says why it matters"
)

local ok2 = pcall(function()
	rt:on("on_match_joined", function() end)
end)
check(not ok2, "a plausible-but-wrong name is rejected")

if failures > 0 then
	print("FAILED: " .. failures)
	os.exit(1)
end
print("all event-name checks passed")
