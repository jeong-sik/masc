# TUI Lane commit receipt evidence

Relates to #41100, audit finding B4. Audit baseline: `1ca0e57699f5258484d9b77ea193e11ba893fca1`. Review base: `a251e19115fa71dff59b2ce726be52e63ee0a073`. The main delta changes Board normalization and unrelated release/PTY fixtures; no receipt, state or renderer source changed.

The routing client now returns its decoded receipt through the async lane-write result. The UI retains the receipt across successful and failed list rereads, separates applied/kept/unpublished from file durability, and wraps its notice at the same width used for list and picker geometry.

## Observed

- Thirteen changed OCaml source/interface files passed `ocamlc -stop-after parsing` with OCaml 5.5.1. Parsing does not establish type or link correctness.
- The actual receipt `.ml`/`.mli` and `test_tui_runtime_config_receipt.ml` were copied to a temporary directory and compiled directly with OCaml 5.5.1, Yojson and Alcotest. All 9 isolated cases passed. The command, source hashes, scope and output are retained in `isolated-receipt-tests.json` and `.log`.
- `git diff --check` passed.

## Not established

No local Dune build, full TUI compile, full state/layout suite, PTY run, HTTP fixture, CI or deployment was run. The added state-transition test covers kept/unpublished receipts, successful/failed rereads, and narrow geometry but has not been executed. The isolated receipt test does not exercise async delivery or rendering. Independent source review is recorded on the PR after the final head is available.

## Remaining execution

Run `test_tui_runtime_listing` and the affected scroll-geometry suites against this candidate, then the real TUI lane editor with applied/kept/unpublished receipts and a failed reread at narrow and ordinary terminal sizes. Preserve the same binary/source identity. These unexecuted scenarios are not claimed as passing evidence.
