# Lane removal eligibility response

Baseline head `4f50f04a29c09f7ec6b0aace326933a5be2bd652`; parent integration remains pending. No backend deletion logic changed.

Web and TUI now mirror `Lane_addon_runtime.remove_configuration_file`: a configured owner requires complete declaration inventory, a unique declaration with the recorded owner revision and no same-ID issue, or an actually absent owned file. Invalid owned files and duplicate IDs are refused. Unrelated issues do not block missing-file cleanup, and manual workers do not require configuration inventory. TUI retains the actual `configuration.revision` independently of package revision and applied-projection fields.

Actual Web RED: four new component cases failed against unchanged baseline product. Final component suite: 34 PASS (28 existing, four refusal cases, two positive absent-file cases); TypeScript and scoped ESLint PASS. The initial path typo produced no source modification and ran a zero-matching-test command; it is not claimed as RED.

Focused OCaml wrapper build and actual native suite: 17 PASS. New decoded-state assertions cover incomplete/invalid/ambiguous declarations plus missing-file and unrelated-issue positives. One introduced full-record-with warning failed the first build, then was corrected without changing assertions.

The initial full native run had 16 PASS and an inherited Flow assertion failure. Exact baseline production/test bytes were temporarily restored, focused-built, and its case 1 actually reproduced the same failure: expected `a: attached · last completed: 1 result row`, renderer reports `1 record`. Existing issue #41174 tracks this stale fixture. Only that expected noun was aligned with the unchanged renderer; all counts and other exact Flow lines remain. Baseline failure and final success logs are retained. The repair bytes were restored before final execution.

Commands: `opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_tui_lane_addons.exe` with `DUNE_JOBS=2`; execute the resulting suite with declared test environment (empty MASC_BASE_PATH/ZAI_API_KEY/TYPESAFEAI_API_KEY, sandbox and Docker playground disabled). Web: `pnpm test src/components/lane-addons-panel.test.ts`, `pnpm exec tsc --noEmit --pretty false`, scoped ESLint on changed panel and test.

No full suite, native TUI/PTY, backend removal execution, hosted CI, or production proof. Parent #41121 propagation and independent review remain pending. Raw logs are copied byte-for-byte including EOF whitespace.

Unrelated held worktree: `.worktrees/fix-pr40794-parent-sync-20261005`, HEAD2319b02fadf10e5ed338776e75cb60cf76db4d57, MERGE_HEAD0f691abfad39ac5da4b19ca6884b7daf84192788; unchanged, not committed or published.
