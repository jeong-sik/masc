# Configuration-path CAS and Live guidance

Response to #41187 comments4179177815 and4179177819. Baseline is `45d51bce1e971795c04bd2b8f5ba928aea8251b0`; later parent-only propagation is intentionally not included in this qualification.

The canonical raw save requires `expected_source_path` alongside `expected_source_revision`. Runtime compares both against the selected file inside the existing write lock, before validation/commit side effects. Missing, empty, NUL and duplicated path fields cannot bypass the guard. The content-revision hash and commit receipt schema are unchanged. This is a required request-field change: older raw callers are refused rather than silently losing the identity guard.

Every raw-save consumer in this owner tree carries the observed path: TUI raw editor, model/account submit, Exact and Browser activity; Web raw editor and Exact activity. Web's existing third request-options argument now requires `expectedSourcePath`. Unknown raw-editor paths produce feedback before dispatch. The TUI Browser/Exact write records capture the original draft path. Live guidance now states its client ownership and lack of server session controls; Automation and Stagehand retain their valid guidance.

Actual RED: a public raw HTTP handler selected a second file with identical initial text, then received the original path and revision. The old server returned HTTP200 and wrote the wrong selected file instead of409. The fixed case verifies409, the newly selected path in the conflict, both files unchanged and no write audit. A separate Live guidance assertion actually failed on the original sentence. Initial baseline compilation failed because the new guidance fixture used an unlinked String_util; it was corrected to the existing local helper before behavioral RED. That authoring error is retained separately.

Actual focused native GREEN: HTTP2, Browser16, Exact15 and runtime-config148 = **181 cases PASS**. Focused TUI executable build passed. The full Browser PTY script passed its ordinary/conflict/save/Help and compact-quit flows with a new assertion that each actual POST retains its observed path. The HTTP test covers canonical server behavior; the PTY uses synthetic HTTP and does not duplicate that server proof.

Actual Web GREEN: **406 tests in four suites PASS**, tsc0. The first Web run had405/406 because an assertion expected the old request shape; tsc also identified nullable raw-editor path. The request assertion and explicit path guard fixed those. ESLint retains the same two inherited costLedger nested-ternary diagnostics at dashboard-runtime.ts989/991 (existing closed issue#37199); other changed files pass. Ruff passes. Pyright retains one identical baseline/current reportIndexIssue in the existing generic Python inventory fixture. Baseline diagnostics were actually executed; no type-clean claim is made. One incorrectly rooted baseline lint invocation is retained as a setup error, superseded by the dashboard-root baseline.

Commands from worktree root unless noted:

```sh
DUNE_JOBS=2 opam exec --switch=5.5.1 -- scripts/dune-local.sh build test/test_dashboard_http_core.exe test/test_tui_browser_activity.exe test/test_tui_exact_activity.exe test/test_runtime_config_validity.exe bin/masc_tui.exe
(cd test && ../_build/default/test/test_dashboard_http_core.exe test 'context-window shrink guard' '13,14')
_build/default/test/test_tui_browser_activity.exe
_build/default/test/test_tui_exact_activity.exe
_build/default/test/test_runtime_config_validity.exe
python3 test/test_tui_browser_activity_pty.py _build/default/bin/masc_tui.exe
# dashboard cwd:
node node_modules/vitest/vitest.mjs run src/api/dashboard-runtime-raw-save.test.ts src/api/dashboard.test.ts src/components/runtime-toml-editor.test.ts src/components/exact-lane-activity-panel.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1
node node_modules/typescript/bin/tsc --noEmit
```

Native build54696 exited0; HTTP2 exited0; other native86932 exited0; final Web8336 exited0; Browser PTY86734 exited0. Raw artifacts remain byte-exact, including compiler/test setup failures, fixture paths and whitespace. Source and five executable hashes are recorded. No full repository suite, TerminalBench, live provider, production or release qualification was run.

## Downstream integration obligations

The current introducing-owner tree lacks the later Browser/Machine Web save producers and Machine TUI write record. On forward propagation, #41191 Browser and #41203 Machine sessions must add `expectedSourcePath: draft.base.source_path` to save options. #41201 Machine's write record and call must carry `draft.base.path`, preserving its independently repaired before/after inventory workspace checks. Do not make the canonical path optional to bypass compile errors. Later model/account forms must retain their own captured-base semantics. This response has not imported any descendant backwards.
