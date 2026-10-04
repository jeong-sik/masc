# Selected Lane navigation

All Lanes links now carry a typed workspace and target through the real router
to the existing receiver. Exact links focus candidate controls or diagnostics;
Browser/Machine links select the matching AST node in the retained TOML draft;
declaration links read the selected file and verify its installation identity;
manual worker links match ID and incarnation. Navigation makes no write request.

Three initial component regressions reproduced lost filter selection, missing
Exact refocus and declaration Retry not reading the file. Independent review
then found four more paths: no Retry after initial inventory failure, discarded
fresh validation metadata for unchanged bytes, old target guards surviving a
new user selection, and a target run list using the previous filter's reading
state. The final Show all regression reproduced retention of the old filter.
The gzip logs preserve all eight failures. Their test snapshots and prior
product commits are pinned in `checks.json`; these failures are separate from
the corrected final execution.

Final focused execution: **434 tests in fourteen files pass**, TypeScript and scoped
ESLint exit 0. `browser-result.json` records **13 actual Chromium flows, 32 API
reads, zero writes, no page errors and no unexpected API routes**. The browser
uses actual styled Status, RouteLink, router, receiver and API decoder code with
synthetic HTTP. It covers same-surface target changes, retained dirty drafts,
Unicode/hash paths, fresh identity mismatch and retry, workspace A/B/A,
incarnation replacement, initial GET failure and direct URL reentry. Screenshots
include selected Runtime/declaration controls and narrow-screen navigation
before/after preventing labels from shrinking into vertical text.

| Changed interface | Direct consumer and check |
| --- | --- |
| `lane_target` URL contract | Inventory → real router → Status → Runtime/Add-ons/diagnostics; browser and component flows |
| Declaration `open`/`read` result and unchanged revision metadata | Existing raw editor and navigation; declaration, Add-ons, package activity/installer and navigation suites |
| TOML target ranges | Actual retained Runtime editor plus quoted/dotted/inline/multiline-decoy boundary cases |
| Target release and diagnostic reading source | New/Open draft, worker/activity/installer callbacks and diagnostic filter/all actions; actual component regressions |

From `dashboard/`:

```sh
node node_modules/vitest/vitest.mjs run src/components/lane-navigation-flow.test.ts src/lib/lane-navigation.test.ts src/components/lane-declaration-editor.test.ts src/components/lane-addons-workspace.test.ts src/components/internal-agents-monitor.test.ts src/components/runtime-toml-editor.test.ts src/components/lane-inventory-panel.test.ts src/components/lane-package-activity-panel.test.ts src/components/lane-package-installer.test.ts src/config/navigation.test.ts src/components/exact-lane-activity-panel.test.ts src/components/browser-lane-activity-panel.test.ts src/components/machine-lane-activity-panel.test.ts src/api/dashboard-runtime-raw-save.test.ts
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/components/internal-agents-monitor.ts src/components/lane-addons-panel.ts src/components/lane-inventory-panel.ts src/components/runtime-exact-lane-editor.ts src/components/runtime-panel.ts src/components/runtime-toml-editor.ts src/config/navigation.ts src/components/lane-navigation.ts src/lib/lane-navigation.ts src/lib/lane-declaration-sessions.ts src/components/lane-declaration-editor.ts src/components/lane-package-installer.ts src/components/lane-navigation-flow.test.ts src/lib/lane-navigation.test.ts
node evidence/2026-10-05-web-lane-navigation/browser.mjs
```

`manifest.json` hashes the final source and artifacts. `focused.txt.gz` preserves the raw final test log, including its trailing blank line.

Parent #41208 advanced to `b80555d8ce98e5c74f2a78257f716a266665877e` during review. The merged source checkpoint is `443b017eecf6589d9577a5db12e1fc0f270cc242`. Its raw-save path contract and setup-resume callback changed, so the final checks include their direct API and three activity-panel suites. The earlier 252-test qualification at `586d3bb4dd92d331b37d5679dd5325d023fad67c` remains historical; the current 434-test and Chromium results were rerun on the new composition. `harness-debug/` preserves
initial synthetic-fixture setup failures (incomplete protocol/Fusion envelopes
and owned-page context setup); these are not product regressions or final PASS
evidence. The harness waits for the selected TOML range, not just an already
focused textarea from the previous route.

No real backend, worker/provider, native TUI, full SPA bootstrap, CI, main
integration, deployment or release was exercised. File save/CAS remains an
explicit editor action. F8 continuous application/cleanup tracking and the
existing shared inventory/Slice cancellation issue remain separate work.
