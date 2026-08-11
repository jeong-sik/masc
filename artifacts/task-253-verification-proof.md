# task-253 verification proof

- Branch: `sangsu/task-253-dashboard-auth`
- Code commit: `e12b44a5f8`
- Verification proof snapshot commit: `74e0996255`
- Base PR head inspected: `bdbdf7aefb7f8a69dd36ac0fba320ef8b56c8429`

## Change

- Removed the route-local `with_public_read` shadow implementations of
  `with_permission_auth`, `with_tool_auth`, `with_tool_actor_auth`, and
  `with_token_permission_auth); dashboard routes now resolve the real
  `Server_auth` combinators.
- Restored tool auth for
  `GET /api/v1/dashboard/runtime-probe`.
- Restored tool/permission auth for Keeper chat-operation and event-queue
  operator GET routes.
- Restored explicit `CanAdmin` auth for Keeper checkpoints and paused-work
  GET routes while leaving the remaining Keeper detail reads public.
- Added HTTP regression coverage: unauthenticated Keeper config mutation
  returns 401, while explicit dashboard runtime-defaults public read returns
  200.

## Verification

- `git diff --check`: pass.
- `dune build --root . --build-dir _build-task253 lib/masc.cmxa`: pass.
- The focused `test_dashboard_execute_output.exe` target could not be built
  because the PR base currently has unrelated server-library failures in
  `lib/keeper_runtime/keeper_event_queue_persistence.ml`,
  `lib/server/server_routes_http_routes_workspace.ml`,
  `lib/server/server_h2_gateway.ml`, and warning-as-error failures in existing
  modules. The new test source emitted no compiler error before those
  dependency failures stopped the target.
- Branch pushed to origin as `sangsu/task-253-dashboard-auth`.
