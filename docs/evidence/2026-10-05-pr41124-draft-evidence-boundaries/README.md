# PR #41124 draft and evidence boundary followup — 2026-10-05

Local response checkpoint `abcc364461` preserves published #41124 `17149d6137986c3291bcadc2d580fb3771df8d57`; a clean real pending merge integrates parent #41122 `2fdea0432d062d334539a83067c81c0046e54a7d`. Parent removal eligibility, typed TUI owner revision, and iterative JSON rendering fixes remain intact.

Three boundaries changed:

- `needsRead` remains a save gate but no longer independently claims unsaved content for before-unload. Actual changed text, nonempty new drafts and retained create edits still guard unload.
- Invalid local filenames (slash, backslash or NUL) produce a visible action error without changing text or dispatching a save.
- Snapshot and retained slice/selection/focus/instance/receipt are rendered only under their accepted workspace authority. Layout cleanup clears retained operator state, while render-time gating withdraws it before that cleanup. Late slice/action callbacks cannot publish under another authority.

Five actual draft/filename regressions failed against the prior code (handle 82494). Its initial sixth slice test used a wrong input label and is excluded from RED evidence. The corrected radio-selection slice test separately failed because A evidence remained after switching to B (handle 30500). The final case also holds a later A slice through a B response with reused row/worker IDs, proving late data cannot restore selection or preservation authority.

Initial two suites passed 61 tests. After parent integration, **77 tests across three suites passed**, handle 18183 exit 0. TypeScript and scoped ESLint passed, handle 42626 exit 0. Exact commands and log/source hashes are in [checks.json](checks.json). Raw logs retain original bytes (including the NUL filename test's literal character); no output was rewritten.

Native `bin/`, `lib/`, and `test/` are byte-identical to the parent, so no native rebuild was repeated. This is focused Web component/API evidence, not browser, hosted CI, native runtime, deployment or RC proof. All handles are terminal; no source changes occurred during execution.
