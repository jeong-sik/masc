# Lane read ownership evidence

Refresh (including refresh after an activity save) and Slice used one cancellation
controller and one error/loading slot. This dropped pending reads and erased
unrelated errors. The panel now owns each read independently; Clear slice cancels
only its query. Requests from an old workspace are still cancelled and ignored.

## Measured checks

- Baseline product at `8c68daa7f7c2f98c3c1e0da1b4df0a3c227ddac5`: 8 failed / 16 passed
  in two component files, recorded in `before.txt.gz`. Seven failing assertions
  concern cancellation/error retention (including explicit activity save); the
  eighth checks the new pending-Slice label.
- Final source checkpoint and file hashes: `checks.json`. Five direct consumer
  suites: **82 passed**, with TypeScript and scoped ESLint exit 0.
- Real Chromium, styled Status/router/panel and actual HTTP decoders: **8 flows,
  19 reads, 1 explicit activity-save write, 0 page errors, 0 unexpected routes**.
  All HTTP is synthetic. The write was intercepted; no operator file changed.
- Desktop: successful inventory refresh retains a failed Slice and its previous
  data. Mobile: both initial reads fail, both errors persist, no loaded data is
  claimed. The screenshots are actual rendered fixture views.
- Independent source review found a P3 wording error when both data sets were
  absent. The three-way wording and its component/browser checks are included.

`harness-debug/` retains earlier harness mistakes separately: the first component
version did not await promise/render settlement; the first browser version also
intercepted Vite source asset paths; its next version expected an error without
the real HTTP client's method/path prefix. These are not additional product
regressions or final results. The corrected baseline/final logs are authoritative.

## Scope

This repairs a prerequisite for F8. It does **not** implement continuous worker
application or historical cleanup tracking. Saved configuration, last observed
inventory and actual cleanup completion remain different facts. Native TUI,
OCaml backend, workers/providers, main integration, CI and deployment were not
executed. No timeout is used to infer product completion.

Run from dashboard with its locked dependencies: the command in `checks.json`,
`node node_modules/typescript/bin/tsc --noEmit`, the scoped command in
`static-checks.json`, and `node evidence/2026-10-05-web-lane-read-ownership/browser.mjs`.
