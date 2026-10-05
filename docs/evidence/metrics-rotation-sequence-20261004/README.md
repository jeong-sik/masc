# Metrics rotation sequence repair

Review finding R1 in #41111; parent d5be9e6f649fb84c63a343bec62d571d58a05f4a.
The parent stops accepting rows after 999 rotations even when only two rows remain.
The candidate extends canonical decimal sequences past three digits and uses the
same numeric ordering in permissive/strict recent reads, range paths and pruning.
The remaining overflow refusal is the representable OCaml integer identity bound,
not a daily rotation cap; the writer never wraps onto an existing segment.

Native results: 20/20 Keeper storage cases (Stdlib and Eio filesystem modes),
including 1,010 writes, reopening, numeric recent/range ordering and pruning
across 999/1000; the complete existing Dated_jsonl suite passes 68/68.
The complete current Dated_jsonl and Keeper_metrics_storage sources were compiled
with OCaml 5.5.1 and cached lower dependencies in an isolated temporary directory.
The Keeper suite uses only a module alias; its tests are otherwise unmodified.
The runner takes CHECKOUT and CACHE_CHECKOUT arguments. The shared root cache
was absent; an existing coherent worktree cache supplied dependencies instead.

Before/after execution is local storage evidence. Full server/TUI, independent
current-head approval, CI, merge and deployment are not established by these logs.
Source hashes bind the evidence; the baseline log remains historical parent proof.
