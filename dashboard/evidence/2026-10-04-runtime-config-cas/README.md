# Web runtime.toml revision-checked save

Issue #41100, audit B1. Implementation base: `dd5e691f2ce78a3dbd10c22965107344c3b39248`.

`saveRuntimeTomlConfig` now requires the revision captured with the editor's source. The raw POST contains `source_text` and `expected_source_revision`; preview remains text-only. A typed HTTP 409 `revision_conflict` carries the current source/path/revision. Missing or malformed conflict fields cannot authorize revision adoption.

The editor preserves its draft and original revision after a conflict. The comparison shows the original and current server text. Reading the current file alone does not replace the draft or save basis. The operator can explicitly adopt the displayed revision while keeping the draft, or separately replace the draft with the displayed current text. Adoption does not submit a write. A later writer can still cause another conflict. An unknown save result preserves the draft and explains that the file may have changed.

## Observed

- Focused Vitest: **320/320**, 3 files, 4.31 seconds. Includes the direct API/editor consumers, 9 new API cases and 4 new editor scenarios. `focused-vitest.log`.
- `pnpm exec tsc --noEmit`: **PASS**, no diagnostics. `typecheck.log` is empty on success.
- Changed-file ESLint: two pre-existing `no-nested-ternary` diagnostics at `dashboard-runtime.ts:987:56` and `:989:7`. The exact same two diagnostics were reproduced on the base file using `git show <base>:dashboard/src/api/dashboard-runtime.ts | pnpm exec eslint --stdin --stdin-filename src/api/dashboard-runtime.ts`. `lint-current.log`, `lint-base.log`.
- Actual Chromium **149.0.7827.55** displayed and interacted with the actual RuntimeTomlEditor and HTTP client through synthetic intercepted responses. Seven scenario assertions passed: draft retention, original-revision POST, explicit adoption without submitting/replacing, subsequent concurrent conflict, separate replacement, non-destructive current-file read, unknown-result retention. `browser-result.json`, `browser.log`, `conflict.png`, `unknown-result.png`. Both screenshots were inspected.
- Expected HTTP 409, 409 and 500 responses produced three browser console resource errors. There were **zero page errors** and no unhandled fixture routes. The evidence does not call the browser console error-free.
- Initial browser harness runs accidentally intercepted `/dashboard/src/api/` module requests. This prevented mount; it was a fixture matcher error. `browser-initial.log` and `browser-failure.json` preserve it. The final driver intercepts only pathnames beginning `/api/`.

Source hashes and exact commands are in `manifest.json`. The driver, HTML and source entrypoint are retained to make the synthetic fixture reviewable. Run Vite from the dashboard with a loopback proxy placeholder, then `node dashboard/evidence/2026-10-04-runtime-config-cas/browser-fixture.mjs`. The fixture intercepts all runtime API calls; it does not contact a production backend. `CAS_FIXTURE_URL` can select another local fixture URL.

## Limits

No backend/native/Dune build, CI, deployment or real filesystem CAS was run. The browser fixture does not prove backend locking, successful durable commits or integration with the separately implemented server/TUI changes. A final independent review is still required. Lane Add-on draft navigation is a separate work unit.

## Current parent integration (2026-10-04)

Current local candidate: checkpoint `7dee734ac427811c6d98ce5a05dcd2e81c168153`
with real merge parent `84e6966c289e3cc493a75740eda3b2e53f56a27e` and the
model-form guarded-save consumer adjustment. Historical files above retain
their original candidates and are not evidence of this integration.

Focused wrapper build passed for runtime validity, dashboard HTTP, config edit
state, and the TUI executable. Current executions passed: runtime validity
144 tests, edit state 4 tests, raw HTTP CAS contract 1 test, actual config-draft
PTY, dashboard typecheck, and 320 tests across the three affected Web test files.
Local logs: `/tmp/pr41114-focused-build2.log`, `/tmp/pr41114-validity.log`,
`/tmp/pr41114-edit.log`, `/tmp/pr41114-http-cas.log`,
`/tmp/pr41114-draft-pty.log`, `/tmp/pr41114-tsc.log`, and
`/tmp/pr41114-web-tests.log`. TUI SHA-256:
`b3f32483db627d1dc5da4f0883eabab8ef3b8189d4afd6257ec319fb831aa219`.
The first focused build exposed the new parent's model-form caller using the
previous helper contract; the current caller sends the revision from its fresh
read and maps the typed receipt/error. This protects read-to-write CAS, not the
revision at which a model/account form was originally opened. No #41119 API
was imported. No current browser, full-suite, release, or deployed-runtime
verification is claimed.
