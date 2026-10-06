# Web MSX/DOS activity settings

This unit adds a dedicated activity draft to each machine in All Lanes. It
uses the existing Runtime preview and revision-checked save API. The file,
commit receipt and last server activity reading are displayed independently.
Neither opening the panel nor changing the draft starts or changes a machine.

Final checks: **134 tests in 4 files**, TypeScript and scoped ESLint passed.
Chromium completed **12 scenarios**, with 15 inventory reads, 5 previews,
4 save attempts (one conflict) and 3 synthetic commits (one lost reply).
There were no page errors, unexpected API requests, model-resume calls or
machine load/restore requests.

## Reproduce the scoped checks

From `dashboard/`, with the lockfile dependencies installed:

```sh
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/lib/machine-lane-activity.test.ts \
  src/components/machine-lane-activity-panel.test.ts \
  src/components/lane-inventory-panel.test.ts \
  src/components/browser-lane-activity-panel.test.ts
pnpm exec tsc --noEmit
pnpm exec eslint src/lib/machine-lane-activity.ts \
  src/lib/machine-lane-activity.test.ts src/lib/machine-lane-activity-session.ts \
  src/lib/machine-lane-observation.ts src/components/machine-lane-activity-panel.ts \
  src/components/machine-lane-activity-panel.test.ts \
  src/components/lane-inventory-panel.ts src/components/lane-inventory-panel.test.ts
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 \
  node --import tsx evidence/2026-10-05-web-machine-activity/browser-fixture.mjs
```

The Chromium fixture uses actual styled Status, router, inventory, machine
editor/session, raw editor and API code. It intercepts every `/api/` request;
its synthetic HTTP responses do not validate real server or machine behavior.
It uses an ephemeral local port and removes its own temporary Vite cache.

`tests.txt`, `typecheck.txt`, `lint.txt` and `browser.txt` preserve the execution
results. `browser-result.json` records the browser version, scenarios, write
requests and errors. Desktop and mobile screenshots are from that same run.
`source-hashes.json` binds these artifacts to the inspected source files.

## Review responses and limitations

Initial review found that whole-document `getStaticTOMLValue` could modify
`Object.prototype` for special TOML keys. The machine reader now uses direct
AST paths and typed values; it does not project the document into a JavaScript
object. Unknown machine names/settings remain errors, including prototype-like
keys. Unrelated provider tables remain untouched. The existing Browser reader's
similar defect is tracked separately; this change does not certify it safe.

`parser/` retains the actual initial helper, isolated-process observations and
same-test before/after logs: 6 failures out of 41 before the response, then all
41 pass. The earlier child-import URL harness failure is separately retained
and is not product failure evidence. Its provenance file pins the relevant bytes.
Committed text logs strip trailing whitespace and surplus final blank lines;
the parser provenance records original and committed artifact hashes separately.
The initial helper source is preserved byte-for-byte.

Successful rereads now clear the obsolete request to reread while keeping
receipts, uncertain delivery and observation errors distinct.

The first browser harness invocation omitted Vite's required proxy environment
variable and failed before rendering. `browser-setup-failure.txt` preserves that
setup error; the documented command supplies an unused loopback destination.
`tests-initial-async-wait.txt` records two assertions that checked the independent
inventory refresh before it settled after an asynchronous token-wait fixture was
introduced. Those cases now await the visible inventory result itself.

These checks do not prove real backend validation/publication, machine owner
execution, native TUI/PTY, CI, main integration or deployment. The direct base
is the separately reviewed TUI editor; changed lower stack heads require their
own composition review. No full local build or CI was run for this unit.
