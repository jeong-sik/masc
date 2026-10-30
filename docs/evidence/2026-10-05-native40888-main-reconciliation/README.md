# Native Stack 40888 reconciliation — 2026-10-05

Published #40824 cf9cea79ccde87c142ebc37ef5d340f309a496a3 and #40884
d7177b8c9d3202d8a21d50817258de34f72f622e were inspected against current main
87123f7df94a27ded447b5b05d01c2f5178de029. Native API membership was exactly
these two open PRs in that order. Existing checked-out branches were preserved;
work used an isolated shared clone under the repository .worktrees directory.

Native rebase replayed historical commits and stopped with six conflicts,
including old modular Python paths. Both local rebase attempts were aborted;
no remote operation was submitted. The final published heads were merged with
main/parent to preserve earlier merge-resolution fixes. The sole parent conflict
in runtime_selection_summary_lines retains both the runtime_option annotation
and the qualified Tui_decode.ro_id field. The child parent-merge was clean.

Executed source coordinates and hashes are in checks.json. Tests ran at the
integrated child, whose production sources equal the integrated parent; two
child regression files extend the native coverage. Focused wrapper build used
`DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build`
with bin/masc_tui.exe and the four test executables recorded in checks.json.
Listing 55, per-keeper routing 98 and decoder 352 tests passed. The config
executable was listed first, then only runtime TOML gate cases 113 and 114 ran:
unassigned default rider and frozen routing snapshot after reload. Both passed.
The Python fixture run_default_route used that actual TUI binary and passed,
including the exact lane-name POST and entry-runtime assertions.

Eight directly affected Web suites passed 377 tests; tsc passed. ESLint reported
two unchanged no-nested-ternary errors at dashboard-runtime.ts989/991, verified
against exact main bytes via stdin. No new errors. ESLint ignores the resolved
schema file by configuration; tsc covered it. The raw Vitest log names all eight
suites. Build logs include existing macOS Keychain deprecation warnings.

Evidence-only additions after execution do not change source. These are focused
local results, not full-suite, TerminalBench, hosted CI, deployment or release
proof. Native Stack publication and current-head review remain separate steps.
