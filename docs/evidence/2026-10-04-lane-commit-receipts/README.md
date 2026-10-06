# TUI Lane commit receipt evidence

Relates to #41100, audit finding B4. Audit baseline: `1ca0e57699f5258484d9b77ea193e11ba893fca1`. Review base: `a251e19115fa71dff59b2ce726be52e63ee0a073`. The main delta changes Board normalization and unrelated release/PTY fixtures; no receipt, state or renderer source changed.

The routing client now returns its decoded receipt through the async lane-write result. The UI retains the receipt across successful and failed list rereads, separates applied/kept/unpublished from file durability, and wraps its notice at the same width used for list and picker geometry.

## Observed

- Thirteen changed OCaml source/interface files passed `ocamlc -stop-after parsing` with OCaml 5.5.1. Parsing does not establish type or link correctness.
- The actual receipt `.ml`/`.mli` and `test_tui_runtime_config_receipt.ml` were copied to a temporary directory and compiled directly with OCaml 5.5.1, Yojson and Alcotest. All 9 isolated cases passed. The command, source hashes, scope and output are retained in `isolated-receipt-tests.json` and `.log`.
- `git diff --check` passed.
- The existing replacement/promotion PTY scenario was updated to read the new pending message and assert that the application receipt remains in the current screen after the new selected model appears. Python AST parsing passed; the PTY scenario was not executed.

## Not established

No local Dune build, full TUI compile, full state/layout suite, PTY run, HTTP fixture, CI or deployment was run. The added state-transition test covers kept/unpublished receipts, successful/failed rereads, and narrow geometry but has not been executed. The isolated receipt test does not exercise async delivery or rendering. Independent source review is recorded on the PR after the final head is available.

## Remaining execution

Run `test_tui_runtime_listing` and the affected scroll-geometry suites against this candidate, then the real TUI lane editor with applied/kept/unpublished receipts and a failed reread at narrow and ordinary terminal sizes. Preserve the same binary/source identity. These unexecuted scenarios are not claimed as passing evidence.

## Current main integration and review repairs

The isolated/parser evidence above belongs to the historical PR source. This
integration merges main `6fc062feee7e33a271e09dc155d9feffee923704` and repairs review
comments 4176228821 and 4176228824: a dismissed notice stays dismissed after a
successful or failed late reread, while Keeper preempted/mixed application results
and their environment-overridden keys produce an attention notice without a
restart requirement. Independent stale-list state remains intact.

The focused repo-local native build passed for the TUI, receipt decoder, runtime
listing and two direct scroll-geometry consumers. Their complete executables
passed 10, 55, 5 and 4 tests respectively (74 total). The actual replacement and
promotion PTY passed with the retained application receipt. Ruff passed; Pyright
reported the same 14 diagnostic signatures as exact main, with no new signatures.
The integrated listing tests explicitly use main's required viewport height and
include its wrapped selection-summary rows; their direct Yojson/Astring library
dependencies are declared. No full suite, deployment or production proof is
claimed. These results do not replace current-head independent review.
