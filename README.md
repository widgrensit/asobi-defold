# asobi-defold

Defold client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend.

## Installation

Add the SDK and the WebSocket extension to your `game.project`:

```
[project]
dependencies#0 = https://github.com/widgrensit/asobi-defold/archive/refs/tags/v1.7.0.zip
dependencies#1 = https://github.com/defold/extension-websocket/archive/refs/tags/4.2.2.zip
```

Then *Project → Fetch Libraries* in the Defold editor. Pin to a tag — `main` is unstable. See [releases](https://github.com/widgrensit/asobi-defold/releases) for available versions.

## Run a backend first

The SDK talks to an Asobi server. The fastest way to get one is the canonical SDK demo backend:

```bash
git clone https://github.com/widgrensit/sdk_demo_backend
cd sdk_demo_backend && docker compose up -d
```

That serves at `http://localhost:8084` (HTTP + WebSocket on `/ws`) with a 2-player `demo` mode. For the full reference game (arena shooter, boons, modifiers, bots) see [`asobi_arena_lua`](https://github.com/widgrensit/asobi_arena_lua).

## Quick Start

The SDK supports both world-mode (persistent shared rooms with zoned interest management) and match-mode (transient matchmade games). Pick the one that fits your game.

> **Defold-specific**: register WebSocket callbacks from a `.script` in `main.collection` (a script that lives for the whole app). Don't register them from a `gui_script` or any collection that gets unloaded — Defold invalidates the WS callback when its owning script is gone.

### Worlds — drop two players into a shared room

The simplest multiplayer pattern. One persistent world, both players walk around, both see each other.

```lua
local asobi = require("asobi.client")

local client

function init(self)
    client = asobi.create("localhost", 8084)

    client.auth.register(client, "player_" .. tostring(math.random(1, 1e9)),
        "pass1234", nil, function(data, err)
        if err then print("register failed: " .. tostring(err.error)) return end

        client.realtime:on("entity_added", function(id, state)
            if id == client.realtime.local_player_id then return end
            -- factory.create("#ghost_factory", vmath.vector3(state.x, state.y, 0))
        end)

        client.realtime:on("entity_updated", function(id, state, changed)
            if id == client.realtime.local_player_id then return end
            -- go.set_position(vmath.vector3(state.x, state.y, 0), ghosts[id])
        end)

        client.realtime:on("entity_removed", function(id)
            -- go.delete(ghosts[id])
        end)

        -- connect() authenticates asynchronously; wait for "connected" before
        -- sending game messages, or they race ahead of the session.
        client.realtime:on("connected", function()
            client.realtime:find_or_create_world("walkers", function(payload, err)
                if err then print("join failed: " .. tostring(err.error)) return end
                client.realtime:send_world_input({kind = "move", x = 500, y = 200})
            end)
        end)
        client.realtime:connect()
    end)
end
```

A complete runnable version is in `example/multiplayer.lua`.

`client.realtime:join_or_host("walkers", cb)` is a convenience alias for `find_or_create_world` - join an open world of that mode, or host a new one, in one race-free call.

> Worlds require a backend with a **world mode**. The `sdk_demo_backend` docker
> quickstart only ships a **match mode**, so run the Matchmaking example below
> against it; Worlds need a world-mode backend (e.g. `asobi_arena_lua`).

### Matchmaking — transient matchmade games

Fastest path: `asobi.quick_start` does guest sign-in, connect, and queue in one
call, with the handler-before-connect ordering handled for you.

```lua
local asobi = require("asobi.client")

function init(self)
    self.client = asobi.quick_start({
        host = "your-env.asobi.dev",   -- ssl defaults to true (port 443)
        mode = "demo",
        on_queued  = function(p) print("queued, need " .. tostring(p.players_needed) .. " more") end,
        on_matched = function(p) print("matched! " .. p.match_id) end,
        on_failed  = function(p) print("failed: " .. tostring(p.reason)) end,
    })
end
```

For entity-sync or full control over the client lifecycle, use the explicit
flow (`asobi.create` + realtime):

```lua
local asobi = require("asobi.client")

local client

function init(self)
    client = asobi.create("localhost", 8084)

    client.auth.register(client, "player_" .. tostring(math.random(1, 1e9)),
        "pass1234", nil, function(data, err)
        if err then print("register failed: " .. tostring(err.error)) return end

        -- The matchmaker places you into a match and pushes match.matched. It
        -- auto-places you, so there is no join step - match.state starts flowing.
        client.realtime:on("match_matched", function(payload)
            print("matched into " .. tostring(payload.match_id))
        end)

        client.realtime:on("match_state", function(payload)
            print("elapsed_ms: " .. tostring(payload.elapsed_ms))
        end)

        -- Always register these three, or matchmaking fails silently:
        -- confirmation that your ticket was accepted, a bad/unknown mode, and a
        -- match that could not start (e.g. a crash in your game's init).
        client.realtime:on("matchmaker_queued", function(p) print("queued " .. p.ticket_id) end)
        client.realtime:on("error", function(p) print("error: " .. tostring(p.reason or p.type)) end)
        client.realtime:on("matchmaker_failed", function(p) print("mm failed: " .. tostring(p.reason)) end)

        -- Wait for "connected" before queueing, or the request races auth.
        client.realtime:on("connected", function()
            client.realtime:add_to_matchmaker("demo")
        end)
        client.realtime:connect()
    end)
end
```

`client.realtime:quick_play("demo")` is a convenience alias for `add_to_matchmaker` if you prefer the intent-named call.

See `example/example.lua` for the matchmaker REST + realtime flow.

> **Testing matchmaking solo.** The matchmaker forms a match only once `match_size`
> players have queued, so a single client against a `match_size = 2` mode waits for a
> second player. To try it on your own: set `match_size = 1` in that mode's `match.lua`
> (a lone ticket matches instantly), or run two clients. Do not queue the same client
> twice to force a match - that submits two tickets and matches the player with
> themselves.

### Drop into a running match — browse and join

The matchmaker places you automatically, but a client can also join a match by
id: browse with `list_matches`, join with `join_match`. A running match accepts
joiners while `player_count < max_players`, so this is the drop-in flow.

```lua
client.realtime:list_matches({mode = "arena", has_capacity = true}, function(payload, err)
    if err then print("list failed: " .. tostring(err)) return end
    local match = payload.matches[1]
    if not match then print("nothing open") return end

    client.realtime:join_match(match.match_id, function(info, join_err)
        if join_err then print("join failed: " .. tostring(join_err)) return end
        print("joined " .. info.match_id .. " (" .. info.player_count .. "/" .. info.max_players .. ")")
    end)
end)
```

`join_match` takes an optional opts table carrying `ctx`, passed to your game
module's join callback untouched — a room code, a team pick:

```lua
client.realtime:join_match(match_id, {ctx = {code = "AB12"}}, function(info, err) ... end)
```

`join_world` takes the same `(world_id, opts, callback)` shape.

> Matches are **unlisted by default** and `listed` is not a Lua global, so a
> mode opts into `list_matches` with `listed => true` in the operator's
> `game_modes` config. Worlds default to listed. See
> [Lobbies](https://github.com/widgrensit/asobi/blob/main/guides/lobbies.md).

## Guest / anonymous auth

Sign a player in with no username or password. You supply a stable
`device_id` and a `device_secret` (base64 of >=32 CSPRNG bytes, generated and
stored by your game — the SDK just passes it through). The same pair resumes
the same guest on later launches.

```lua
local asobi = require("asobi.client")

local client = asobi.create("localhost", 8084)

client.auth.guest(client, device_id, device_secret, function(data, err)
    if err then print("guest sign-in failed: " .. tostring(err.error)) return end
    -- data.created is true on first sign-in, absent on resume.
    print("signed in as guest " .. tostring(data.player_id))
end)
```

### Let the SDK manage the device credentials (opt-in)

Generating the pair, encoding the secret correctly, and persisting it across
launches is the same boilerplate in every game, so there is an opt-in helper
that does it for you. `guest_device` loads the saved pair (or generates and
persists one on first run via `sys.save`) and signs in — one call:

```lua
client.auth.guest_device(client, function(data, err)
    if err then print("guest sign-in failed: " .. tostring(err.error)) return end
    print("signed in as guest " .. tostring(data.player_id))
end)
```

Pass options to control storage or supply your own randomness:

```lua
client.auth.guest_device(client, {
    app = "mygame",            -- sys.get_save_file app name (default "asobi")
    file = "guest_device",     -- save file name
    random_bytes = my_csprng,  -- function(n) -> n bytes; override the default RNG
}, function(data, err) ... end)
```

On **HTML5** the bytes come from the browser's `crypto.getRandomValues` via the
`html5` module, so web builds get a real CSPRNG with no extra setup. If that
call is unavailable the helper raises rather than falling back — on web the
seeded RNG below is not random enough to keep two browsers apart, and a shared
`device_id` means two players sharing one account. Pass `random_bytes` to
override if you hit this.

**Upgrading a web build:** credentials stored by v1.13.0 or earlier are
discarded on first launch, because a seeding bug in those versions gave every
browser the same `device_id`. Affected players get a fresh guest; the account
they had was shared with every other web player of that game, so it was never
solely theirs. Native builds are unaffected and keep their stored pair.

On every other platform the default RNG is best-effort seeded `math.random`
(Defold has no core CSPRNG) — acceptable for a guest credential that is
generated once and stored, but **for production you should pass `random_bytes`
backed by a crypto extension** so the secret is cryptographically random. A
custom `random_bytes(n)` must return at least `n` bytes (the helper asserts
this). If you want to manage
storage yourself (e.g. an OS keychain), keep using `guest(client, id, secret, …)`
directly — `asobi.device.generate()` / `asobi.device.load_or_create()` are also
exposed if you want just the pieces.

To forget the local guest (a "switch account" or "play as someone else"
action), erase the stored keypair — the next `guest_device` mints a
brand-new guest:

```lua
local device = require("asobi.device")
device.clear()  -- pass the same {app=..., file=...} you signed in with
```

`clear` is local-only; it does not delete the server account (pair it with
`logout` to end the session, or `upgrade_guest` first to keep the guest as a
real account). Note `logout` on its own keeps the keypair, so the same guest
resumes on the next `guest_device`.

### Deleting the account

For an actual "delete my data" request, `clear` is not enough — the account
and everything on it stay on the server. `erase_self` deletes them:

```lua
-- Guest or provider-only account: no password to confirm with.
client.players.erase_self(client, nil, function(data, err)
    if err then
        print("erase failed: " .. err.code .. " - " .. err.error)
        return
    end
    print("account erased")
end)

-- Account with a password: it must be echoed.
client.players.erase_self(client, "secret123", function(data, err) end)
```

Irreversible. A wrong password comes back as `err.code ==
"player.confirmation_failed"` (403) and changes nothing.

On success the local session is cleared, because the server deleted the token
pair in the same transaction. Anything afterwards on that session is a `401` —
for a retried erase, read that as "it already worked". The device keypair is
*not* cleared, so call `device.clear()` too if the next launch should not sign
straight back in as a new guest.

Needs a server carrying `POST /api/v1/players/me/erase`; older ones answer 404.

**If you mint a throwaway pair per launch** (`device.generate()` — a testing
trick, see the multiple-players guide) every run leaves an account behind, and
on asobi Cloud nothing reaps them. Either call `erase_self` on shutdown, or use
`guest_device` so relaunching resumes one player instead of creating another.

Later, convert the guest into a full account (keeps the same `player_id`).
The call is authenticated with the guest's current access token, so run it
after a successful `guest(...)`:

```lua
client.auth.upgrade_guest(client, "chosen_name", "pass1234", function(data, err)
    if err then print("upgrade failed: " .. tostring(err.error)) return end
    -- Tokens are rotated to the claimed account automatically.
    print("upgraded to " .. tostring(data.username))
end)
```

### Testing with two clients on one machine

The saved pair identifies the machine, so two instances of the same build sign
in as the same player: matchmaking will not pair them and their views drift. In
a dev build, skip persistence and mint a throwaway guest per launch instead:

```lua
local device = require("asobi.device")
local device_id, device_secret = device.generate()
client.auth.guest(client, device_id, device_secret, function(data, err) ... end)
```

For stable test players, give each instance its own save file with
`--config=asobi.player_slot=2` and a `file = "guest_device_" .. slot` option.
Full recipe, plus why two players can still land in separate matches:
[Testing with multiple players](https://github.com/widgrensit/asobi/blob/main/guides/testing-multiple-players.md).

## Multiplayer (entity sync)

The SDK maintains a managed registry of all entities in your current world or match and applies the server's partial diffs for you. Game code listens to high-level callbacks instead of merging diffs by hand:

```lua
client.realtime:on("entity_added", function(id, state)
    -- A new player or NPC joined; `state` is the full initial state.
end)

client.realtime:on("entity_updated", function(id, state, changed)
    -- An entity moved or changed. `state` is the FULL merged state
    -- (never partial); `changed` lists which fields the server diffed.
end)

client.realtime:on("entity_removed", function(id)
    -- Despawn the ghost.
end)

-- Iterate or query:
for id, state in pairs(client.realtime.entities) do
    if id ~= client.realtime.local_player_id then
        -- render ghost
    end
end
```

The entity registry is populated from **diff frames** shaped `{tick, updates = [...]}`. World-mode (`world.tick`) always sends these, so entity sync is automatic there. Match-mode only fills the registry if **your game emits the same `{tick, updates}` shape** from its `match.state`. Many match games (including the `sdk_demo_backend` demo mode) send a custom `match.state` instead, e.g. a `players` map. For those, register `match_state` and read the payload directly:

```lua
client.realtime:on("match_state", function(payload)
    for id, p in pairs(payload.players or {}) do
        if id ~= client.realtime.local_player_id then
            -- render ghost at p.x, p.y
        end
    end
end)
```

See `example/multiplayer.lua` (world-mode entity sync) and `example/example.lua` (the match-mode loop).

## Server-pushed game events

A Lua game script pushes to clients two ways, and they land on different
callbacks.

`game.send(player_id, message)` targets one player and arrives as
`game_message`:

```lua
client.realtime:on("game_message", function(payload)
    print(payload.message)
end)
```

`game.broadcast(event, payload)` goes to everyone in the match or world. The
event name is chosen by your script, so it arrives on the catch-all
`match_event` (or `world_event` from a world script) with the name as the first
argument:

```lua
-- server: game.broadcast("players_total", { value = state.players_total })
client.realtime:on("match_event", function(event, payload)
    if event == "players_total" then
        print("players: " .. tostring(payload.value))
    end
end)
```

Events asobi itself broadcasts (`match.state`, `match.finished`, the
`match.vote_*` family, and so on) keep their own named callbacks and do not
also fire `match_event`.

## Extensions (RPC)

Server extensions expose methods over the same socket. Call one with
`realtime:rpc`:

```lua
self.realtime:rpc("quests.claim", {quest_key = "daily"}, function(result, err)
	if err then
		if err.code == "quests.already_claimed" then
			print("already claimed today")
		end
		return
	end
	print("reward: " .. result.reward)
end)
```

Calls are correlated by cid, so several can be in flight at once and may answer
out of order. `params` and `result` are always tables, so either can gain a
field without breaking a shipped game.

On failure `err` is the shared error object - `{code, message, details}`.
Branch on `err.code`; `message` is for humans and may be reworded at any time.

## Features

- **Auth** - Register, login, guest (anonymous), guest upgrade, token refresh
- **Players** - Profiles, updates
- **Worlds** - List, create, find-or-create, join, leave, input, entity sync
- **Matchmaker** - Queue, status, cancel
- **Matches** - List, join, details
- **Leaderboards** - Top scores, around player, submit
- **Economy** - Wallets, store, purchases
- **Inventory** - Items, consume
- **Social** - Friends, groups, chat history
- **Tournaments** - List, join
- **Notifications** - List, read, delete
- **Storage** - Cloud saves, generic key-value
- **Realtime** - WebSocket for worlds, matches, chat, presence, matchmaking
- **Extensions** - Call server extension methods over RPC

See the [WebSocket protocol guide](https://github.com/widgrensit/asobi/blob/main/guides/websocket-protocol.md) for the full event surface.

## License

Apache-2.0
