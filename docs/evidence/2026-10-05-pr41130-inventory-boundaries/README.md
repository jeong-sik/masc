# PR #41130 inventory boundaries — 2026-10-05

Response checkpoint `2b815e33c3` plus real clean pending merge of published direct parent #41124 `e7eb8f219b487a6755f0317e0d6e9be59bab5691`. Fresh REST identified Native Stack #41123 position 6; #41126 belongs to a different stack and was not skipped or imported.

- An invalid explicit configuration root produces an incomplete declaration observation with the resolver warning, matching maintenance/editor authority. Retained configured rows remain unobserved rather than claiming absence.
- Retained current-format bindings require incarnation to equal instance ID, matching the existing action fence. A bad record produces its own diagnostic and partial retained inventory while valid siblings remain visible; it does not rewrite declaration observations.
- `Declaration_file` explicitly recognizes the suffix-only filename `.toml`. Enumeration stays unchanged; server, TUI and Web filename eligibility now accept that same direct child. Traversal, backslash, NUL and non-TOML safeguards remain.

Actual RED: three new inventory cases failed; the TUI suffix-only case failed (handle 15506). A separate inherited Issue #41174 wording failure also appeared and was corrected by the incoming parent, not by this response. The first RED build exposed test access to abstract `Inventory.t`; the test was corrected to use public JSON, then build 93613 passed before RED execution.

Final focused native build 53630 passed. Native run 54867 passed **8 inventory + 17 TUI tests**. Web/check handle 59751 passed **78 tests across three suites**, TypeScript and scoped ESLint. The integration initially exposed two old tests explicitly rejecting `.toml`; their assertions were moved to explicit acceptance checks rather than dropped, preserving all other filename rejection cases. Those intermediate failure logs are retained separately.

[checks.json](checks.json) records commands, handles, binary hashes and raw log hashes. Raw outputs retain original bytes, including any EOF warnings. No source changes occurred during active runs. Parent H2 authorization, removal eligibility, workspace draft/evidence guards and JSON formatter repairs remain present. No full build, hosted CI, browser, new PTY, deployment or RC qualification is claimed.
