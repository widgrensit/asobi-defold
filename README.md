# asobi-defold

Defold client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend.

## Installation

Add the SDK and the WebSocket extension to your `game.project`:

```
[project]
dependencies#0 = https://github.com/widgrensit/asobi-defold/archive/refs/tags/v1.2.1.zip
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

> Worlds require a backend with a **world mode**. The `sdk_demo_backend` docker
> quickstart only ships a **match mode**, so run the Matchmaking example below
> against it; Worlds need a world-mode backend (e.g. `asobi_arena_lua`).

### Matchmaking — transient matchmade games

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

        -- Wait for "connected" before queueing, or the request races auth.
        client.realtime:on("connected", function()
            client.realtime:add_to_matchmaker("demo")
        end)
        client.realtime:connect()
    end)
end
```

See `example/example.lua` for the matchmaker REST + realtime flow.

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

The SDK listens to both `world.tick` and `match.state` server frames internally, so it works the same in world-mode and match-mode games. You don't need to register on `on_world_tick` / `on_match_state` yourself unless you want the raw frame.

See `example/multiplayer.lua` for a runnable starter.

## Features

- **Auth** - Register, login, token refresh
- **Players** - Profiles, updates
- **Worlds** - List, create, find-or-create, join, leave, input, entity sync
- **Matchmaker** - Queue, status, cancel
- **Matches** - List, details
- **Leaderboards** - Top scores, around player, submit
- **Economy** - Wallets, store, purchases
- **Inventory** - Items, consume
- **Social** - Friends, groups, chat history
- **Tournaments** - List, join
- **Notifications** - List, read, delete
- **Storage** - Cloud saves, generic key-value
- **Realtime** - WebSocket for worlds, matches, chat, presence, matchmaking

See the [WebSocket protocol guide](https://github.com/widgrensit/asobi/blob/main/guides/websocket-protocol.md) for the full event surface.

## License

Apache-2.0
