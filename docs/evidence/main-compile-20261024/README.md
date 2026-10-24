# Main compilation boundary repair

## Source identity

- Code PR: [#45683](https://github.com/jeong-sik/masc/pull/45683).
- Code head: `4748ef0815e389b0283dc50e81251197b41b65f1`.
- Reviewed base: `9b70cf4eac0e6fa93641e13048cec16e08c211b4`.
- Canonical source diff SHA-256: `a4a0f4c5668096627bd36821aa2ee6a05883588d222f9506051e62a7b22c9d98`.
- Carried source: [#45675](https://github.com/jeong-sik/masc/pull/45675), head `50fdf1166ec1381f17db1d87d1b4cd71679308ba`. Its branch and checkout were preserved.

## Observed failure and integration repair

The completed [main build 40055723252](https://github.com/jeong-sik/masc/actions/runs/40055723252) at `fa5f1b7c69c5cfee5c816fc8166e5356e4dfafab` fails in the operator build at `lib/task/anti_rationalization.ml:700` with `Unbound module Tool_bridge`. Its subsequent tree check also reports `Unbound module Keeper_request_source`. The code PR does not claim this old run executed the new head.

Task handlers cannot depend on the root library that consumes them. The existing result projection moves to the shared `masc.tool_projection` leaf; the root adapter and Task handlers use that one implementation. Root-library references in the affected test entrypoints are qualified through `Masc`. No string inference, policy default, retry gate or duplicate formatter was added.

The original repair and newer main independently added the Librarian executable's `masc_core` and `masc.prompt_registry` dependencies. Carrying both additions produces duplicate entries. The code PR preserves the entire current-main `bin/dune` byte for byte; each dependency occurs once in that executable stanza. Newer main already contains the original repair's direct `Prompt_registry` reference, so that source change is not repeated.

The callback-based repairs #45664 and #45669 remain separate alternatives. Their code was not combined with the extraction, and this report does not close or certify either PR.

## Direct checks performed

| Changed boundary | Direct consumer | Command or observation | Result and limit |
|---|---|---|---|
| Projection implementation and public type re-export | Task handlers and root `Tool_bridge` | Byte comparison with #45675 `tool_projection.ml` | Identical; SHA-256 `a7327de38ec859bee703bbad1d14d4ef188862a12af43e68b226ec76699634c1`. This preserves the carried source, not proof of typing or runtime behavior. |
| Changed OCaml source and test entrypoints | 34 changed ML/MLI files | `ocamlc -stop-after parsing -c <file>` for each file | All 34 parse; no typecheck, link or executable test. |
| Librarian dependency declaration | `masc_librarian_continuity` executable | Compare `bin/dune` bytes with reviewed base and inspect the executable stanza | Identical to main; each disputed dependency declared once. No Dune build was run locally. |
| Release fragment | Changed fragment | `python3 scripts/changelog-fragments.py check-files changelog.d/45683.md` | One fragment passes. |
| Source whitespace | Complete code diff | `git diff --check origin/main...HEAD` at the code worktree | Pass; source formatting only. |

## Review and execution status

The independent MASC source-review request for the exact code head was accepted as operation `kmsg-86ae3302016b1d24a5fb523bd3e07631` at `2026-10-24T03:21:53Z`; its returned state was `queued`. Queue acceptance is not completed review or approval.

The complete two-layer stack was rebased once with `gh stack rebase` onto main `9b70cf4eac0e6fa93641e13048cec16e08c211b4`. `git range-diff` reports both code commits unchanged from the original `d12d2420`-based source. The complete canonical diff identity changes because main updated source/test blobs in the direct consumer context; unchanged patches do not certify that changed context. The old source-review scope and queued requests remain historical; current-head approval must cite the new identities.

Fresh compile execution for the current code head is pending. The earlier frozen top `7f30d5b39a5ff9b3bc901476623e99dddb9d6693` has explicitly requested [operator compile 40058167064](https://github.com/jeong-sik/masc/actions/runs/40058167064), [tree typecheck 40058238566](https://github.com/jeong-sik/masc/actions/runs/40058238566), and [two-suite behavior 40058240701](https://github.com/jeong-sik/masc/actions/runs/40058240701). The selected behavior suites are `test_anti_rationalization_empty_reject,test_keeper_tool_matrix_cases`, with `minimal=true`. Dispatch is not success. Those executions are scoped to their old source tree and do not prove the later main integration. #45675's older build/test claims are not evidence for this code head. No local Dune build, executable test, installation or live runtime verification was performed by this external coding session. Native stack membership and the eventual completed build result must be read from the current PR/API and actual run before integration.
