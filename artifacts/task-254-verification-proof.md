# task-254 verification proof

- Base PR head checked: `bdbdf7aef8b8a69dd36ac0fba320ef8b56c8429`
- Worktree: `sangsu/task-254-delete-auth`
- Scope: restore the shared token/permission authorization boundary for dashboard destructive actions.

## Source evidence

`lib/server/server_dashboard_http_delete_actions.ml` now keeps `open Server_auth` and removes the feature-local `with_token_permission_auth` bypass and fixed `dashboard_feature_actor`. The nine destructive route registrations resolve `with_token_permission_auth ~permission:Masc_domain.CanAdmin` from `Server_auth`, covering board, task, goal, agent purge, and moderation actions.

## Regression coverage

`test/test_dashboard_execute_output.ml` adds an HTTP router harness and two checks for `POST /api/v1/dashboard/board/delete`:

- no bearer token -> expected HTTP 401;
- an `Auth.create_token` Admin token -> expected HTTP 400 from the handler's invalid JSON body, proving the authenticated request reaches handler parsing rather than being rejected by auth.

## Verification

Passed:
- `ocamlc -stop-after parsing lib/server/server_dashboard_http_delete_actions.ml test/test_dashboard_execute_output.ml`
- `git diff --check`

The focused build command was attempted:

```
MASC_DUNE_THROTTLE=0 MASC_SKIP_OPAM_LOCK=1 MASC_DUNE_ALLOW_BARE_DUNE=1 \
  bash scripts/dune-local.sh build test/test_dashboard_execute_output.exe
```

It is blocked by pre-existing PR-base errors outside this change:

- `lib/keeper_runtime/keeper_event_queue_persistence.ml:588` partial application type error;
- `lib/server/server_routes_http_routes_workspace.ml:825` unbound record field `target`;
- `lib/server/server_h2_gateway.ml:1029` unbound module `Keeper_chat_operations`;
- warning-as-error unused declarations in `server_dashboard_http_keeper_api_types.ml` and `server_ide_http.ml`.

Therefore the two HTTP regression cases could not execute in this checkout; the source-level parser check and exact failing build output are recorded above.
