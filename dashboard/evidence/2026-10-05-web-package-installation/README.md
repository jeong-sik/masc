# Web package selection and schema input

Parent: `e4fad56d68d4e2401191e8e83668c4b449f8c4d5` (#41205).

The real Add-ons panel now uses the local catalog/preview API, a recursive package
input form, a retained input owner, and the existing declaration owner/editor.
Preparing creates a separate local draft. Only explicit Save TOML calls the
existing declaration endpoint. No implicit attach or worker operation is added.

The existing tool-executor form falls back to raw JSON for object arrays and
objects; its validation only checks required values. This package form instead
handles the restricted schema contract declared in Lane_addon_action.schema_node,
using the existing common inputs/buttons and declaration storage. The backend
remains authoritative. Unsupported schema shapes produce an error rather than
claiming raw JSON is a nested field editor.

## Executed evidence

- `tests.txt`: 102 tests in 5 focused files, including the actual 9 shipped
  binding schemas, preservation of zero/false/absence, oneOf branch editing,
  prototype-like keys, stale/failed previews, unsubmitted paths, workspace changes, independent
  raw drafts and explicit save. Existing Add-ons/editor regressions are included.
- `typecheck.txt`, `lint.txt`: TypeScript and scoped ESLint.
- `checks.json` records actual command exit codes. Text logs only trim trailing
  whitespace at EOF; `.txt.gz` files retain the exact raw output bytes.
- `path-input-before.json/txt`: the new regression failed before fixing two
  unsubmitted path fields that were lost on remount. The identical test now
  passes, including workspace isolation, with no preview/save dispatch.
- `browser-result.json`: actual styled components/session/API in Chromium with
  synthetic HTTP. Seven scenarios, nine recorded Lane API reads and one explicit
  declaration create. Bootstrap dev-token is supplied separately. Zero page
  errors, unexpected API routes and mobile horizontal overflow.
- Desktop/mobile form and saved-draft screenshots show those actual components.
- `manifest.json` records inspected/changed sources and artifact hashes.

The browser fixture initially omitted required action_schema and gave an invalid
output-port shape. The actual decoder refused the snapshot and disabled actions;
`initial-fixture-validation.json` preserves that failure. Fixture setup also
needed the Vite proxy environment and a pathname check to avoid intercepting
source-module /src/api URLs. Native select accessible names were made explicit
before the final browser pass. These setup failures are not before/after product
regression proof. `before-explicit-select-labels.json/png` retain that initial
browser locator failure where available.

## Reproduction and limits

From dashboard, use the matching frozen lockfile's dependencies:

```
node node_modules/vitest/vitest.mjs run src/lib/lane-binding-form.test.ts src/components/lane-package-installer.test.ts src/components/lane-declaration-editor.test.ts src/components/lane-addons-workspace.test.ts src/components/lane-addons-panel.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1
node node_modules/typescript/bin/tsc --noEmit
node evidence/2026-10-05-web-package-installation/browser.mjs
```

The fixture blocks unknown API routes and uses a non-serving local proxy target.
No real backend file, manifest/parser execution, image inspection, worker, native
TUI/PTY, deployment or CI was exercised. It mounts the actual panel, not the full
SPA. Output suggestions use the observed applied producer in the same Run; other
source identities remain schema-field input. Web package on/off, target links,
continuous submitted-revision/application tracking, Goal work and main/runtime
integration remain under the full goal. The inherited path-check/reopen race is
still a shared loader follow-up, not a security repair completed here.
