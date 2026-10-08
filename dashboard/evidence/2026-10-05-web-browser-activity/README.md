# Web Browser activity controls

All Lanes Browser details now own a workspace/backend activity draft. Toggle is
local; explicit Save runs the existing server preview and raw-file revision CAS.
Navigation retains the draft, and another backend/raw editor's draft remains
independent. Workspace/connection changes invalidate the save basis and ignore
late completions. Conflicts require explicit activity-only reapplication.

Browser activity is published during backend raw save in the parent change.
This control therefore re-reads inventory on its commit receipt and does not
call model setup resume. Enabled is not an installed executor or healthy session.
Startup paths still require a server restart. Accepted flat automation paths
move into the canonical table when editing Automation; the AST editor also
supports inline, dotted and quoted forms.

## Executed checks

From the repository root (matching dependency manifest and lockfile):

```sh
cd dashboard
node node_modules/vitest/vitest.mjs run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 src/components/browser-lane-activity-panel.test.ts src/components/lane-inventory-panel.test.ts src/components/exact-lane-activity-panel.test.ts
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/lib/browser-lane-activity.ts src/lib/browser-lane-activity-session.ts src/lib/browser-lane-observation.ts src/components/browser-lane-activity-panel.ts src/components/browser-lane-activity-panel.test.ts src/components/lane-inventory-panel.ts
cd ..
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 node dashboard/evidence/2026-10-05-web-browser-activity/browser-fixture.mjs
```

75 tests in three files passed (38 Browser, 37 existing Exact/inventory).
Full dashboard TypeScript and the named source lint passed. Tests exercise
actual sessions, components and TOML editing, with API/consumer refresh mocked.
They cover explicit writes, preview refusal, CAS/reapply, independent drafts,
A-B-A late responses, changed paths, uncertain receipts, read generations,
backend isolation, missing executor configuration and navigation during save.

Chromium uses actual Status, router, inventory, Browser controls, raw editor and
API decoders with synthetic HTTP. Eight checks passed: draft-only actions,
navigation retention, conflict preservation, field-only reapplication with
flat-path migration, other backend/path/comment retention, raw draft preservation,
unconfigured Stagehand on versus executor absent, and mobile layout. Three
explicit previews and raw saves included one rejected conflict and two commits;
no model setup resume or unexpected API was called. Five inventory reads, zero
page errors. Screenshots disable animations to capture settled controls.

Initial test fixture names used Automation instead of the fixture's actual
label; initial TypeScript ran before all tests were added and detected then-unused
imports. The Chromium first attempt selected duplicate Stagehand labels before
filter rendering settled (`browser-initial-failure.json`). Selection now uses
row identity. These were harness corrections, not product behavior repairs.
Logs have trailing whitespace and outer blank lines normalized for the diff.

## Remaining scope

P3: existing enabled inline comments survive, but comments attached to moved flat
path assignments are not retained by the shared AST delete/insert helper. Other
source ranges and all path values survive. Full backend/path validation remains
in the server preview; the local reader only interprets selected activity.

No actual backend preview/save acceptance, Runtime publication, Browser executor,
native TUI/PTY, Dune, CI, main integration or deployment was run for this change.
Synthetic HTTP cannot establish those outcomes. F2 retains those integration
steps; package and machine controls, Goal gaps and the separate B10 Settings
workspace defect remain in the broader work.
