# #41172 recovery and parent integration

Original #41172 `226f5f1a024f450f530b1d7e557d4324c4741bcb` is integrated
with published #41166 `06db5c20c90570676de28d885ec04c3f0fac93b5`.
Fresh REST returned OPEN and omitted the stack key; membership is unknown, not
an explicit null. No stack metadata was changed.

The two merge conflicts retain the parent's writable/adoption distinction and
superseded/changed-authority read retry, alongside the child's observation
revision invalidation. The clean-read retry review findings are thereby handled
by the canonical parent implementation. The full scoped run includes its clean
automatic reload and dirty comparison regressions.

Remaining repairs:

- Both Runtime setup-resume controls notify Exact observations and refresh
  dependent runtime consumers through an authority-guarded completion callback.
- `announceRuntimeTomlCommitted(authority)` in `runtime-toml-session.ts` shares
  the existing workspace-owned Settings commit signal. Raw and Exact Activity
  writes use it without replacing the raw draft. The Activity notification runs
  after owned setup completion, including a returned failure: a file commit
  remains a commit while live application remains explicitly unconfirmed.

Actual component regressions use both Runtime and All Lanes readers after an
automatic resume failure followed by successful manual retry. The Settings
regression uses the actual Activity session, verifies its receipt and failed
setup notice, then requires fresh mounted Settings snapshots while the raw
editor is unmounted. The first RED file contains a valid manual-retry failure;
its Settings case had an invalid receipt fixture and is not Settings regression
proof. `settings-commit-red.log` is the corrected Settings RED, after verifying
the receipt and failed-resume path. Earlier fixture attempts are superseded.

Commands in dashboard:

```sh
pnpm test src/components/exact-lane-activity-panel.test.ts src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts src/components/lane-inventory-panel.test.ts src/components/model-setup-resume-control.test.ts src/api/dashboard.test.ts
pnpm exec tsc --noEmit --pretty false
```

All 427 tests in six suites pass; typecheck passes. The two new targeted cases
also passed independently. Changed-file ESLint reports two inherited
`no-nested-ternary` errors at dashboard-runtime.ts:989/991. An actual parent-byte
lint run reports exactly those same errors. The other changed files have no
lint diagnostics. Existing issue [#37199](https://github.com/jeong-sik/masc/issues/37199)
was closed with the disposition to address this style baseline when that decoder
changes; this repair does not alter that decoder. This is not a whole-lint PASS.
The parent-byte lint swap finished and restored before tests ran.

Native source/tests match the published parent; no native build or PTY was
repeated. Historical browser evidence is unchanged and no browser run, backend
write, model execution, full CI or release proof is claimed. Raw logs are copied
unchanged, including trailing blank lines.
