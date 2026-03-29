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
