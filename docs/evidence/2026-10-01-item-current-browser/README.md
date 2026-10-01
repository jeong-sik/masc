# Current Item browser behavior and installed boundary

Source: `d688917369e608765472b63f6a2c307b42a66b90` (#40288).

Two real Chromium scenarios ran against that unchanged source's production Item components and CSS through a local Vite development server. Account HTTP data and roster/workspace observations were synthetic. The portrait endpoint deliberately returned 503: the screenshots show the badge fallback and do not prove native PNG rendering.

- Account scenario: seven screenshots cover desktop/mobile, pending read withdrawal, free ownership change, price-only change, failed read and recovery. Five account reads completed; no uncaught page errors.
- Workspace scenario: eight screenshots cover fixed Keeper/wallet/outfit across A→B→A, held old response release, current response, and unknown workspace withdrawal. Four scoped reads completed; no uncaught page errors. Browser abort outcomes are recorded without claiming an aborted JavaScript promise was forced to resolve.

The historical receipt reports an initial failed account/workspace attempt, but its raw output and Vite log were not retained. The claimed dependency-optimization cause cannot be verified from these artifacts and is withdrawn. Only the separately preserved successful scenario manifests establish their recorded passes.

## Installed observation

The retained read-only observation identifies installed server version 0.49.0, embedded commit `4f3f70f7909bc440e3c305c0941250ef39ac0245`, readiness true, and an authenticated Item read for `code-reviewer` returning HTTP404. It does not retain that Keeper's roster entry or a successful control request. Unknown Keeper and missing route are therefore not distinguished; the prior “installed route gap” conclusion and uncaptured 27-Keeper/source-tree claims are withdrawn.

The browser artifacts establish their named frontend fixture behavior. They do not prove installed route availability, current-head native purchase/equip/restart behavior, native PNG output, an installed Items screen, or release readiness. No build, CI, install, runtime restart, purchase or configuration change was performed.

Hashes and exact source/runtime provenance are in [receipt.json](receipt.json). Original scenario manifests are retained in the account and workspace directories.

A repeated authenticated HTTP observation is retained in [installed-http-observation.json](installed-http-observation.json): exact Item response status/body and readiness response, plus selected health/build/path fields. Request credential values and dev-token responses are omitted. The observation has its own timestamp and build identity.

## Preview failure and restoration

Scenario source `05044d48a75b1e3036e14210990fe4ec04362edf` adds Chromium clicks for the unowned beanie preview. The mocked 503 PNG produces the explicit preview-failure alert. Returning to the observed outfit removes the alert and selection while preserving the real displayed account observation. The expanded scenario passed with nine screenshots and five account reads; its production component source remains unchanged from d688. The preview directory preserves that separate manifest and captures. This still does not prove native preview pixels.

## Scroll-corrected capture follow-up

`scroll-corrected/receipt.json` records the base commit and exact modified scenario hash. Actual Chromium passed the updated scenario: nine captures and five account reads. Before every capture the scenario returns the document to x=0/y=0 and waits two animation frames; the preview-failure capture was visually inspected with the navigation rail at the top. The portrait route records the selected beanie request and holds the restored current-portrait response until the scenario verifies loading, then verifies its settled badge fallback. HTTP account data and portrait503 responses remain synthetic.

The first follow-up attempt reached an unavailable local Vite server because its required proxy configuration had not been set. Its exact failure log and receipt are retained separately as `scroll-corrected/initial-server-not-ready.*`; it is not a pass. This new captured failure does not reconstruct the missing historical cold-run log.
