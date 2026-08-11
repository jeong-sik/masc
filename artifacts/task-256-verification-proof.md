# task-256 verification proof

## Acceptance evidence

- lib/server/server_h2_gateway.ml preserves token/permission authorization for POST /api/v1/board/reactions
  - The H2 with_h2_token_permission_auth wrapper now calls authorize_token_bound_permission_request with the route's permission and threads the canonical actor only after auth and rate-limit checks.
  - The POST route continues to declare permission:Masc_domain.CanVote; the catalog route remains on with_h2_public_read.
- Unauthenticated H2 board-reaction mutation is rejected
  - test_board_reaction_mutation_rejects_anonymous_auth exercises the same token-bound CanVote authorization primitive without a credential and asserts Unauthorized.
  - The H2 parity test asserts auth failures are sent through h2_respond_auth_error, so the POST route cannot fall back to anonymous public-read behavior.
- Authenticated caller with CanVote can toggle a reaction
  - test_dashboard_dev_token_can_vote_as_credential_owner verifies a dashboard dev-token resolves to the canonical dashboard actor with CanVote.
  - The H2 parity test verifies the authenticated actor reaches Server_board_reaction_http.toggle_json with actor; the existing Board reaction suite covers the toggle/untoggle behavior.

## Verification run

- ocamlc -stop-after parsing lib/server/server_h2_gateway.ml — pass.
- ocamlc -stop-after parsing test/test_board_rest_routes.ml — pass.
- ocamlc -stop-after parsing test/test_mcp_h1_h2_admission_parity.ml — pass.
- git diff --check — pass.
- python3 scripts/ci/check_h2_route_auth_parity.py — pass (99 H2 route arms scanned).
- Focused Dune build attempted:
  bash scripts/dune-local.sh build test/test_board_rest_routes.exe test/test_mcp_h1_h2_admission_parity.exe
  - Blocked by existing baseline errors before test execution: lib/keeper_runtime/keeper_event_queue_persistence.ml:588, lib/server/server_routes_http_routes_workspace.ml:825, lib/server/server_h2_gateway.ml:1039 (Keeper_chat_operations), plus existing warning-32 failures in dashboard/IDE modules.
  - No error remained in the changed helper or added tests after the final build attempt.
