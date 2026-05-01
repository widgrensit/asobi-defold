# Defold SDK smoke test

Unlike the other SDKs in the fleet, Defold's SDK uses engine-only APIs (`http.request`, `websocket` via `defold-websocket`), so it can't run from a plain Lua interpreter. The smoke test must run *inside* a Defold project.

## How to run it locally

1. Start [`sdk_demo_backend`](https://github.com/widgrensit/sdk_demo_backend):

   ```bash
   git clone https://github.com/widgrensit/sdk_demo_backend.git
   cd sdk_demo_backend
   docker compose up -d
   ```

   The backend listens on `http://localhost:8084` (HTTP + WebSocket on
   `/ws`) with a 2-player `demo` mode.

2. Create (or open) a minimal Defold project that depends on this SDK. Add both `asobi-defold` and this `smoke_tests/` directory to the project's `library_dependencies` in `game.project`, or drop them in locally.

3. Add a main collection with a `main.script` like:

   ```lua
   local smoke = require("smoke_tests.smoke")

   function init(self)
       smoke.run("localhost", 8084, function(ok)
           if ok then
               print("smoke: PASS")
               sys.exit(0)
           else
               print("smoke: FAIL")
               sys.exit(1)
           end
       end)
   end

   function update(self, dt)
       smoke.update()
   end
   ```

4. Run the project via the Defold editor or headless build:

   ```bash
   dmengine_headless
   ```

## CI status

No CI job yet — `dmengine_headless` requires pulling the Defold engine and a signed build, which is a separate ~2hr setup. The smoke script itself is kept parity with the other SDKs so it can be wired up later.

## Canonical scenarios

Same contract as every other SDK — see [widgrensit/sdk_demo_backend/SMOKE.md](https://github.com/widgrensit/sdk_demo_backend/blob/main/SMOKE.md).
