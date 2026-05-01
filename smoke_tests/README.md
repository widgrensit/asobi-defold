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

## Scope: single-client subset

The `asobi.realtime` module currently uses module-level state, so two distinct clients cannot coexist in the same Lua VM. Until that's refactored, this smoke runs the **single-client subset** of [SMOKE.md](https://github.com/widgrensit/sdk_demo_backend/blob/main/SMOKE.md):

- `POST /api/v1/auth/register` (Scenario 1, step 1)
- `/ws` connect + `session.connected` event (Scenario 1, steps 2-3)
- `matchmaker.add` → `matchmaker.queued` round-trip (proves outbound WS messages reach the server and inbound dispatch works)

The full 2-player matchmaker → `match.matched` → `match.input` → `match.state` flow needs an SDK refactor (per-instance `realtime`) before it can run here.
