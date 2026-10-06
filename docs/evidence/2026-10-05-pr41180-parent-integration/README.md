# PR #41180 parent integration — 2026-10-05

Original head `70a3abb094378f7cf7f28468be3ba5c966ad703d`, clean real pending merge of published parent #41178 `874f30e416f139a5882a7b90151f9c522aed40de`. Fresh REST omitted the stack key: membership is unknown. Existing approval applies to the original head only.

The unique clean-draft read/reopen behavior, five added native cases, and PTY assertions are preserved. Dirty drafts, uncertain writes, and changed paths still require explicit recovery. Parent compact Help protection and Curator availability wake behavior remain intact. Integration required no product or test edits; the fragment received its PR citation.

## Actual integrated verification

- Focused wrapper build of `bin/masc_tui.exe` and `test/test_tui_exact_activity.exe`: PASS, handle 82370.
- Native activity suite: 15 tests PASS.
- Full existing activity PTY: PASS against the newly built TUI; verifies clean external read/reopen without writes plus compact Help, retained edits, preview failure, CAS conflict/reapply, and Required refusal. Native and PTY commands completed in handle 41516, exit 0.
- Ruff: PASS. Pyright: two inherited object-index diagnostics in the inventory fixture, not type-clean. Their rule/message multiset matches retained #41166 output; the exact two producer lines are unchanged from the merged parent. One added docstring line shifts their reported positions by one.

[checks.json](checks.json) records commands, binary hashes and exact raw log hashes. The historical parent Pyright output is labeled separately. Raw outputs retain original bytes, including any evidence-only EOF whitespace warnings.

Historical leaf evidence under `2026-10-04-tui-activity-current-file` remains unchanged. These are focused native and synthetic HTTP terminal checks, not a full suite, live backend/model execution, browser run, deployment, or RC proof. All execution handles terminated before evidence preparation.
