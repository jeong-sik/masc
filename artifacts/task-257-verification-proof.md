# task-257 verification proof

## Scope

Task-257 targets PR #28243. The fetched current PR head is `bdbdf7aefb7f8a69dd36ac0fba320ef8b56c8429` (the task description's older head is stale). Implementation commits:

- `b39ba433a5` — restore sensitive keeper GET permissions and H2 enforcement.
- `bf83fc2c58` — add H1/H2 admission-parity assertions.

## Changes

- `lib/server/server_dashboard_http_keeper_api_types.ml`
  - `keeper_get_permission` now returns `Some Masc_domain.CanAdmin` for exact keeper routes ending in `/checkpoints`, `/paused-work`, `/raw-traces`, `/raw-trace`, or `/memory-journal`.
  - Trailing segments do not match; ordinary keeper read projections remain public.
- `lib/server/server_h2_gateway.ml`
  - Added a keeper-GET-specific token-bound permission wrapper.
  - H2 keeper GET dispatch consults the same sensitive route map; protected routes reject missing/invalid/underprivileged credentials before the public response projection runs.
  - Other H2 mutation authorization helpers were left unchanged because they belong to separate tasks.
- `lib/server/server_dashboard_http_keeper_api_types.mli`
  - Updated the contract comment to describe sensitive-vs-public keeper GET policy.
- `test/test_dashboard_http_core.ml`
  - The exact permission matrix covers raw-traces, raw-trace, memory-journal, paused-work, checkpoints, trailing-segment rejection, and an ordinary public trajectory read.
- `test/test_mcp_h1_h2_admission_parity.ml`
  - Static parity assertions cover H1 permission-map/token wrapper selection and H2 permission-map/token-bound wrapper selection.
  - Existing raw-trace auth regression covers anonymous rejection, Worker forbidden, and Admin allowed.

## Verification

- `ocamlformat --check lib/server/server_dashboard_http_keeper_api_types.ml lib/server/server_dashboard_http_keeper_api_types.mli lib/server/server_h2_gateway.ml test/test_dashboard_http_core.ml test/test_mcp_h1_h2_admission_parity.ml`: exit 0.
- `git diff --check`: exit 0.
- `bash scripts/dune-local.sh build lib/server/server_dashboard_http_keeper_api_types.ml`: exit 0.
- Focused `test/test_dashboard_http_core.exe` build was attempted. The PR head cannot complete that executable because of pre-existing unrelated errors:
  - `lib/keeper_runtime/keeper_event_queue_persistence.ml:588` partial-application type error.
  - `lib/server/server_routes_http_routes_workspace.ml:825` unbound `request.target`.
  - Existing unused-value warnings in `lib/server/server_ide_http.ml`.
  - Existing `lib/server/server_h2_gateway.ml:1043` unbound `Keeper_chat_operations` reference.
  These errors occur outside the changed permission implementation; the target types module builds independently.
- The coverage checker was invoked against `main` after the implementation commit and reported `Skipped: opt-out via commit message` from the inherited PR history; it was not counted as a pass.

## Acceptance mapping

- `lib/server/server_dashboard_http_keeper_api_types.ml keeps sensitive keeper diagnostic paths admin-gated`: exact suffix map returns `CanAdmin`, and H1/H2 dispatches consume it.
- `Unauthenticated raw-traces/checkpoints/memory-journal requests are rejected on H1 and H2`: H1 uses `with_token_permission_auth`; H2 uses the new token-bound permission wrapper; parity tests assert both route selections, and raw-trace auth regression covers the credential outcomes.
- `Intended public keeper read projections remain available without admin auth`: non-sensitive paths still return `None` from `keeper_get_permission` and route to public read wrappers.
