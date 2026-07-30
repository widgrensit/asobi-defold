# Defold SDK smoke test

Unlike the other SDKs in the fleet, Defold's SDK uses engine-only APIs (`http.request`, `websocket` via `defold-websocket`), so it can't run from a plain Lua interpreter. The smoke test must run *inside* a Defold engine.

## How CI runs it

The `engine-smoke` job in [`.github/workflows/test.yml`](../.github/workflows/test.yml) downloads pinned `bob.jar`, bundles the project (including the `defold-websocket` native extension via Defold's hosted build server), and runs the resulting Linux binary against a local `sdk_demo_backend` Docker stack. The Defold version is pinned in the workflow env; bump it deliberately when upgrading.

The prebuilt `dmengine_headless` is **not** used: the headless variant strips `http.request`, which the SDK's REST layer needs.

## How to run it locally

1. Start [`sdk_demo_backend`](https://github.com/widgrensit/sdk_demo_backend):

   ```bash
   git clone https://github.com/widgrensit/sdk_demo_backend.git
   cd sdk_demo_backend && docker compose up -d
   ```

   The backend listens on `http://localhost:8084`.

2. From this repo root, fetch matching tooling (replace versions with what's pinned in `.github/workflows/test.yml`):

   ```bash
   curl -fSL -o bob.jar \
     https://github.com/defold/defold/releases/download/1.12.3/bob.jar
   ```

3. Resolve dependencies, bundle, and run:

   ```bash
   java -jar bob.jar --root . resolve
   java -jar bob.jar --root . \
     --platform x86_64-linux --variant debug --archive \
     --bundle-output dist \
     build bundle
   ASOBI_URL=http://localhost:8084 ./dist/asobi/asobi.x86_64
   ```

The engine exits 0 on `[smoke] PASS`, non-zero on failure or timeout. Bundling needs network access to Defold's build server (`build.defold.com`) for the websocket extension; it usually completes in 10-15 seconds.

## Scope: full 2-client SMOKE.md flow

Runs the canonical [SMOKE.md](https://github.com/widgrensit/sdk_demo_backend/blob/main/SMOKE.md) flow with two clients in the same Lua VM:

- `POST /api/v1/auth/register` for two distinct players (Scenario 1, step 1)
- Both `/ws` connect + `session.connected` (Scenario 1, steps 2-3)
- Both `matchmaker.add` → `match.matched` with the same `match_id` (Scenario 2)
- Client A sees `match.state`, sends `match.input {move_x=1}`, and confirms its own `x` advances past `x_initial + 10` (Scenario 3)

## game.send round-trip scenario (`send_roundtrip_test.lua`)

`smoke.lua` covers state broadcast but never `game.send`.
`send_roundtrip_test.lua` covers the server-push path that silently broke
in widgrensit/asobi#235 / widgrensit/asobi_lua#103: client sends
`match.input {message = ...}`, the server's `handle_input` echoes it back
via `game.send`, and the client asserts the `game_message` callback fires
with the right payload and input counter. It also documents the join
contract: the matchmaker auto-joins matched players, so `match_matched`
means you are in - a wire `match.joined` only answers an explicit join.

Run it like the smoke, but bundle with the bootstrap pointed at
`/smoke_tests/roundtrip/main.collectionc` and a backend whose mode `echo`
echoes input via `game.send` (any script whose `handle_input` calls
`game.send(player_id, {echo = input.message})`).
