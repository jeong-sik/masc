# Local Exec Core Inventory — RFC v5 T0 (placeholder)

This file is populated by `scripts/exec_corpus_report.py --write` after a
5-cal-day observation window with `MASC_EXEC_TAP=1` enabled on a running
server (`server_runtime_bootstrap.ml`) or worker (`masc_worker_run.ml`).

## Observation setup

1. Build the tree (worktree or main):
   ```
   dune build
   ```
2. Run the server with the tap enabled:
   ```
   MASC_EXEC_TAP=1 \
   MASC_EXEC_TAP_OUT=audits/exec-corpus.jsonl \
   dune exec -- ./bin/main_eio.exe ...
   ```
3. Let the workload accumulate for at least 5 calendar days **or** until
   the JSONL has `N ≥ 200` lines (whichever is later).
4. Produce the report:
   ```
   python3 scripts/exec_corpus_report.py --write
   ```

## A0 proceed gate

From RFC v5 T0 exit criteria:

- `known_class_ratio ≥ 0.85` → proceed to **A0** (IR types + Menhir
  skeleton).
- `< 0.85` → scope re-evaluation (subset expansion vs typed-tool
  whitelist), per RFC v5 risk register R1.

Report output replaces everything below this line when the script runs
with `--write`.

---

_No data captured yet.  Install the tap, let the corpus accumulate, then
run the report._
