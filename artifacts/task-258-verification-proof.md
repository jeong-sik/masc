# task-258 verification proof

## Scope

Restored the shared `Server_auth.with_tool_auth` combinator in
`lib/server/server_routes_http_routes_activity.ml` instead of the PR-local
`with_public_read` shadow. The H1 board reaction mutation also uses the
existing token-bound `CanVote` boundary; the reaction GET projection remains
public.

## Acceptance mapping

- The keeper delegate, sub-board create/delete/update, board vote/post/comment/comment-vote, prompt override, and runtime parameter mutation routes now resolve through `Server_auth.with_tool_auth`.
- The board reaction POST route resolves through `with_token_permission_auth ~permission:CanVote`; its GET route remains a public read projection.
- `test/test_board_rest_routes.ml` adds source wiring assertions, a missing-token matrix for every activity mutation family, and an authorized dashboard-token board-vote check.

## Checks

- `ocamlformat --check lib/server/server_routes_http_routes_activity.ml test/test_board_rest_routes.ml` — passed (exit 0).
- `git diff --check` — passed (exit 0).
- `bash scripts/dune-local.sh build test/test_board_rest_routes.exe` — blocked before the focused target compiled by existing PR-base errors:
  - `lib/keeper_runtime/keeper_event_queue_persistence.ml:588` partial-application type error.
  - `lib/server/server_routes_http_routes_workspace.ml:825` unbound `request.target`.
  - `lib/server/server_h2_gateway.ml:1029` unbound `Keeper_chat_operations`.
  - Existing warning-as-error failures in `lib/server/server_dashboard_http_keeper_api_types.ml` and `lib/server/server_ide_http.ml`.

The focused build failure is recorded separately from the auth changes; no
new error from the changed route or test was observable before those base
failures stopped compilation.
