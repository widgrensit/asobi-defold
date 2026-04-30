# asobi-defold

Defold client SDK for the [Asobi](https://github.com/widgrensit/asobi) game backend.

## Installation

Add as a dependency in your `game.project`:

```
[project]
dependencies#0 = https://github.com/widgrensit/asobi-defold/archive/main.zip
```

## Quick Start

```lua
local asobi = require("asobi.client")

local client

function init(self)
    client = asobi.create("localhost", 8080)

    client.auth.login(client, "player1", "secret123", function(data, err)
        if err then return end
        print("Logged in as: " .. data.username)

        -- REST APIs
        client.players.get_self(client, function(player, err)
            print("Name: " .. player.display_name)
        end)

        -- Real-time
        client.realtime.on("match_state", function(payload)
            print("Tick: " .. tostring(payload.tick))
        end)

        client.realtime.connect()
        client.realtime.add_to_matchmaker("arena")
    end)
end
```

## Multiplayer (entity sync)

The SDK maintains a managed registry of all entities in your current
world or match and applies the server's partial diffs for you. Game
code listens to high-level callbacks instead of merging diffs by hand:

```lua
client.realtime.on("entity_added", function(id, state)
    -- A new player or NPC joined; `state` is the full initial state.
end)

client.realtime.on("entity_updated", function(id, state, changed)
    -- An entity moved or changed. `state` is the FULL merged state
    -- (never partial); `changed` lists which fields the server diffed.
end)

client.realtime.on("entity_removed", function(id)
    -- Despawn the ghost.
end)

-- Iterate or query:
for id, state in pairs(client.realtime.entities) do
    if id ~= client.realtime.local_player_id then
        -- render ghost
    end
end
```

The SDK listens to both `world.tick` and `match.state` server frames
internally, so it works the same in world-mode and match-mode games.
You don't need to register on `on_world_tick` / `on_match_state`
yourself unless you want the raw frame.

See `example/multiplayer.lua` for a runnable starter.

## Features

- **Auth** - Register, login, token refresh
- **Players** - Profiles, updates
- **Matchmaker** - Queue, status, cancel
- **Matches** - List, details
- **Leaderboards** - Top scores, around player, submit
- **Economy** - Wallets, store, purchases
- **Inventory** - Items, consume
- **Social** - Friends, groups, chat history
- **Tournaments** - List, join
- **Notifications** - List, read, delete
- **Storage** - Cloud saves, generic key-value
- **Realtime** - WebSocket for matches, chat, presence, matchmaking

## License

Apache-2.0
