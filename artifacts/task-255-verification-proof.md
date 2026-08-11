# task-255 verification proof

- Source base: PR #28243 head `bdbdf7aefb7f8a69dd36ac0fba320ef8b56c8429`.
- Worktree: `sangsu/task-255-ide-auth`.
- Changed files: `lib/server/server_ide_http.ml`, `.mli`, `lib/server/server_h2_gateway.ml`, and `test/test_server_ide_http.ml`.

## Contract evidence

1. **lib/server/server_ide_http.ml does not trust anonymous caller-supplied keeper_id for durable writes**
   - H1 annotation POST/DELETE use `with_token_permission_auth ~permission:Masc_domain.CanBroadcast`.
   - H2 annotation POST/DELETE use `with_h2_ide_annotation_auth`, which calls `authorize_token_bound_permission_request`.
   - `bind_annotation_keeper_id` derives the stored identity from `auth_identity` and rejects a requested `keeper_id`.

2. **Annotation deletion enforces stored-owner/capability authorization instead of delete_any for the public route**
   - Both H1 and H2 annotation deletion paths call `Ide_annotations.delete ~keeper_id`.
   - The `delete_any` call was removed from `server_ide_http.ml`.
   - Owner mismatch returns a forbidden response and logs the rejection.

3. **Regression tests cover anonymous create attribution and cross-owner delete rejection**
   - `test_post_annotations_rejects_anonymous_create`: no token is rejected with 401.
   - `test_post_annotations_rejects_client_keeper_id`: token identity cannot be overridden by body `keeper_id`.
   - `test_post_annotations_binds_token_identity`: durable annotation attribution is the authenticated keeper.
   - `test_delete_annotation_rejects_cross_owner`: Bob cannot delete Alice's annotation; Alice can delete it.

## Verification

- `ocamlc -stop-after parsing` passed for the changed ML/MLI and test source files.
- `git diff --check` passed.
- Focused Dune build was attempted with `scripts/dune-local.sh build test/test_server_ide_http.exe`; it was blocked before the changed modules by the pre-existing error at `lib/keeper_runtime/keeper_event_queue_persistence.ml:588` (partial application/type mismatch). No unrelated file was changed to bypass that blocker.
