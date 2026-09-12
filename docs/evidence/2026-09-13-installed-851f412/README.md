# Installed 851f412 acceptance — 2026-09-13

Installed the paired macOS ARM artifact from Release 34710741534 after its ARM job succeeded and exact-source Test 34710740227 passed all 15 requested targets (228 cases). The helper matched source bytes, and installation verified the binary, 651 Dashboard files, four companions and runtime bundle. This does not claim other Release platforms passed.

Running source is `851f412a88f4d5bf290dfa67ac60c4b78bb3ebb1`, binary SHA256 `41a75acff6d190e767cebee3b53c371ed643293a41e1f1b5d93a6c5ab88c180d`, owned PID 39080 on port 18951. Health is `ok`; config errors are zero. The prior owned process was replaced using its source/hash/PID receipt. The separate media acceptance folder records actual original-file CLI inspection.

## Preserved state and Chat

The pre/post restart captures include canonical `tasks/backlog.json`, `goals.json`, runtime and both selected Keeper TOMLs. All 352 scoped files were byte-identical. This is scoped byte preservation, not proof of semantic memory continuity or an atomic whole-workspace snapshot. Three selected Goals remain `awaiting_confirmation`; no human approval was inferred.

Installed Chat acceptance passed again on the original autonomous Edit execution `exec-1789223431021-0129`. Actual API, 83 manifest-matching assets, real worker, before/after bytes and reconstructed displayed diff passed desktop/mobile checks. This observes a historical actual Edit, not a fresh autonomous model turn. See `chat/receipt.json` and screenshots.

## LSP remains incomplete

The full installed IDE sent the correct `textDocument/didOpen` body (`let value =\n`, version 1) through the real WebSocket. This resolves the previous empty-body observation. However the actual language server produced no diagnostic notification and returned `no document found with uri` for inlay hints. The probe timed out waiting for the initial diagnostic marker; it did not reach didChange/diagnostic-clearing acceptance. `lsp/receipt.json` deliberately has `probe_passed: false` and retains the exact frames and error. No new source change was made to the probe-owned file before this failure, and no server restart was attempted to conceal it.

Next investigate backend document delivery during lazy language-server startup. Preserve this failure as the installed baseline for that repair. Code provenance PR 35654 and independent source UX PRs 35664/35667 are not included in this installed binary; their source/merge status is separate.
