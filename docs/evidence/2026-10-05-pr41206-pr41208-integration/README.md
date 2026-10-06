# Web package installer and activity integration

The actual published #41205 parent is `000697850f49ce9366fc17f3533fbb6bc6ba4a93`. Original #41206 `fa6a2426e3793354ba647045842c7066d06038c0` merged it cleanly into actual intermediate commit `c1feb86e5a1dfe9b403c42da37a64d6bf2649e36`. Original #41208 `ebf7e16b4f7651dc32b76ca7d1165c79c284b3cd` then merged that intermediate cleanly. Each missing changelog PR citation was added. No production or test assertion changes were needed.

Actual local qualification is for this combined leaf, not independent execution of either original PR. The union of seven direct Web suites passed all 125 cases; TypeScript and scoped ESLint produced no errors. Existing installer/activity browser scripts were copied byte-exact to new output directories, still mounting the original fixture URLs and actual integrated components. The historical artifacts remain unchanged.

The installation browser run passed seven scenarios, nine Lane reads and one explicit create. The activity browser run passed eight scenarios, fourteen reads and four explicit saves (including one conflict and one simulated lost response). Both report no page errors, unexpected API routes or mobile horizontal overflow. Synthetic HTTP and isolated Vite were used; there is no live backend file, worker cleanup, provider, full SPA, CI or release claim. New screenshots/results live under `dashboard/evidence/2026-10-05-pr41206-integrated-browser` and `dashboard/evidence/2026-10-05-pr41208-integrated-browser`.

`bin`, `lib`, `test`, `packages` and Dune inputs are byte-identical to the qualified #41205 parent. No native rebuild or rerun was performed. Parent Machine stdio proof remains its own scoped evidence.

Commands from dashboard, with dependencies from the matching unchanged lockfile:

```sh
node node_modules/vitest/vitest.mjs run src/lib/lane-binding-form.test.ts src/components/lane-package-installer.test.ts src/lib/lane-package-activity.test.ts src/components/lane-package-activity-panel.test.ts src/components/lane-declaration-editor.test.ts src/components/lane-addons-workspace.test.ts src/components/lane-addons-panel.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/api/lane-package-catalog.ts src/components/lane-addons-panel.ts src/components/lane-binding-form.ts src/components/lane-declaration-editor.ts src/components/lane-package-installer.test.ts src/components/lane-package-installer.ts src/lib/lane-binding-form.test.ts src/lib/lane-binding-form.ts src/lib/lane-declaration-sessions.ts src/lib/lane-package-installation-session.ts src/components/lane-package-activity-panel.test.ts src/components/lane-package-activity-panel.ts src/lib/lane-package-activity-session.ts src/lib/lane-package-activity.test.ts src/lib/lane-package-activity.ts
node evidence/2026-10-05-pr41206-integrated-browser/browser.mjs
node evidence/2026-10-05-pr41208-integrated-browser/browser.mjs
```

Combined checks handle78844 exited0; browser65136 and49956 each exited0. Raw logs are preserved byte-for-byte, including Node deprecation warnings and EOF whitespace; checks pin source and browser artifacts. Browser executables use the available installed Chromium; recorded versions are in each result JSON.
