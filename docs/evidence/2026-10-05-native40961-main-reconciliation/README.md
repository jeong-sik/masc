# Native Stack 40961 reconciliation — 2026-10-05

All seven API-confirmed members were merged bottom-up from their exact published
heads onto main87123f7df94a27ded447b5b05d01c2f5178de029 in an isolated shared
clone under .worktrees. In particular #40960 9c0485 was used although #40966's
REST base still named its older parent. Draft #40981 remains Draft. No remote
branch, PR base, approval, thread or native-stack state was changed here.

The first five merges were clean. #41033's one worker-test conflict was resolved
by preserving both contracts: inspect the returned outcome before any recovery
scan, then verify the terminal journal and untouched fallback obstruction after
the first cold receipt read. #41126 then merged cleanly. Source review found the
extracted retain_sampling_inline helper had not inherited #40960's newer
canonical/fallback classification. The actual listed worker case2 failed on the
integrated tree: canonical absent plus fallback directory produced `sampling
outcome blob is not a regular file`. The raw RED and source/binary identity are
retained. This is a reproduced integration defect, not a new failure invented
for existing released code.

The repair is three added/two removed lines in that helper: use a regular
fallback if present; otherwise reconstruct the absent canonical path from the
durable journal. Existing ownership, symlink/hardlink, durability, digest,
startup-only corrupt repair and query budget checks are unchanged. The test
still proves no repeated model invocation and preserves the obstructing entry.

Focused resource-limited wrapper builds used DUNE_JOBS=2 and opam5.5.1 for the
six executables listed in checks.json. Final native results: worker30, server
sampling17, receipt recovery11, Lane Add-on22, sources15, MCP integration27:
122 passed. Executions used the declared test/dune environment values recorded
in checks.json, plus DUNE_SOURCEROOT. Actual Python MCP fixture compute suite38
passed before the OCaml-only helper fix; its source remained unchanged.

Checksums cover raw logs, source and binaries. The manifest mapping was captured
after the final documentation-only propagation; those documentation changes did
not alter executed source. No full suite, heavy TUI, TerminalBench, browser,
provider invocation, hosted CI, deployment or release success is claimed.
