# PR #41172 auth-followup

Starting published head `c82f1ac2c1c733c2608eee5d7a3d4b86b882ab66`.

Exact follow-up now keeps beforeunload guarded while a verified file receipt still awaits setup resume. Receipt certainty is unchanged. Raw Runtime write finalization asks the existing ensure method to refresh only the same owned, nonuncertain session; clean invalidated bases refresh, dirty intent and unknown writes remain guarded. The canonical raw API classifies structured401/403 authorization refusal before the handler using the existing typed rejection, retaining exact route/method, typed auth field and all application/timeout ambiguity exclusions. No arbitrary other4xx classification was introduced.

Actual RED:4 failures (401,403,followup unload,clean write-finalization reread) and68passes across2suites. GREEN adds unstructured-auth and unknown-write controls:219tests across4suites passed (rawAPI,Exactactivity,raweditor,Settings). TypeScript passes. ScopedESLint has2unchanged costLedgerRead nestedternary diagnostics989/991; exactbaseline stdin check reports identical errors, tracked earlier in closedissue#37199. Other4changedfiles lint passes. Rawlogs preserved. An initial403test used a placeholder authcode; finalfixture uses producer's insufficient_role code. This does not change the RED status-path failure.

Commands from dashboard: pnpm test src/api/dashboard-runtime-raw-save.test.ts src/components/exact-lane-activity-panel.test.ts src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts; pnpm exec tsc --noEmit; scoped eslint on the five changed files. Baseline: git show HEAD:dashboard/src/api/dashboard-runtime.ts piped to pnpm exec eslint --stdin --stdin-filename src/api/dashboard-runtime.ts.

Execution is local mocked-HTTP component/API evidence only, not browser/native/provider/full-suite or final-chain proof. Raw logs are tracked byte-exact; hashes are in checks.json.
