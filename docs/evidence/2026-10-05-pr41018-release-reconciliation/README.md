# Release fixture reconciliation for #41018

Merge original #41018 with the actual named release parent `bdd448e956fab264219713b26bd554d3023dfed4`. Seven conflicts preserve parent workspace withdrawal, true disconnect, resource revision freshness, compact/short layout, and child typed PNG, Mosaic accessory and Item withdrawal assertions. This is isolated preparation; it does not select or qualify a release.

Initial Ruff reported three undefined `refreshes` references: an automatic merge retained the assertions but removed their producer. Restoring the complete parent resource scenario also restores numbered resource responses. The historical failing lint log remains unmodified. Final Ruff passed all four changed Python files. New badge fixture payload validation removed one additional Pyright diagnostic; the isolated parent test tree and final four files both report the same 400 existing diagnostics (filename/rule/message multiset), not a clean type-check.

Focused build command: `opam exec --switch=5.5.1 -- env DUNE_JOBS=2 bash scripts/dune-local.sh build bin/masc_tui.exe test/test_keeper_portrait_http.exe test/test_tui_keeper_portrait.exe` (exit 0).

The two actual native executables passed 19 and 12 cases with `MASC_TUI_FORCE_COLOR=1`. Python imported test modules from this checkout and invoked `resource_workspace_withdrawal` (both initialize/read), `run_http_badge_refresh_regression`, `mosaic_resizes`, and `item_account_withdraws_unread_authority` (default and roster). All five groups passed using this checkout's real TUI binary and synthetic HTTP fixtures. After adding the payload shape assertion, the badge scenario alone was rerun and passed. Other checked source bytes remained unchanged. Resource withdrawal raw output includes BrokenPipeError from intentionally abandoned fixture requests; the assertions and process exited successfully.

Independent source review found the resource mismatch before this run and accepted its parent restoration. Full Behavior, hosted CI, RC, deployment and TerminalBench were not run. Source diff whitespace check passed; inherited historical screen captures have preserved trailing spaces and are not rewritten.
