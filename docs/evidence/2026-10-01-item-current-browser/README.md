# Current Item browser behavior and installed boundary

Source: `d688917369e608765472b63f6a2c307b42a66b90` (#40288).

Two real Chromium scenarios ran against that unchanged source's production Item components and CSS through a local Vite development server. Account HTTP data and roster/workspace observations were synthetic. The portrait endpoint deliberately returned 503: the screenshots show the badge fallback and do not prove native PNG rendering.

- Account scenario: seven screenshots cover desktop/mobile, pending read withdrawal, free ownership change, price-only change, failed read and recovery. Five account reads completed; no uncaught page errors.
- Workspace scenario: eight screenshots cover fixed Keeper/wallet/outfit across A→B→A, held old response release, current response, and unknown workspace withdrawal. Four scoped reads completed; no uncaught page errors. Browser abort outcomes are recorded without claiming an aborted JavaScript promise was forced to resolve.

The author reported a failed cold attempt with six account reads and a workspace wait timeout, followed by successful reruns. No raw failed-run/Vite log was retained, so the proposed dependency-reload cause is unverified; the failure report is not a reproducible diagnostic artifact.

## Installed observation

The retained historical observation identifies server version 0.49.0, embedded commit `4f3f70f7909bc440e3c305c0941250ef39ac0245`, readiness true and an authenticated Item HTTP 404 for `code-reviewer`. The exact Keeper roster entry and source inspection were not preserved with that response. This evidence alone cannot distinguish a missing Item route from an unknown Keeper, and does not establish an installed route gap.

These captures document the historical frontend fixture runs only. They do not prove current-head native purchase/equip/restart behavior, native PNG output, an installed Items screen, or release readiness.

Hashes and exact source/runtime provenance are in [receipt.json](receipt.json). Original scenario manifests are retained in the account and workspace directories.

A repeated authenticated HTTP observation is retained in [installed-http-observation.json](installed-http-observation.json): exact Item response status/body and readiness response, plus selected health/build/path fields. Request credential values and dev-token responses are omitted. The observation has its own timestamp and build identity.

## Preview failure and restoration

Scenario source `05044d48a75b1e3036e14210990fe4ec04362edf` adds Chromium clicks for the unowned beanie preview. The mocked 503 PNG produces the explicit preview-failure alert. Returning to the observed outfit removes the alert and selection while preserving the real displayed account observation. The expanded scenario passed with nine screenshots and five account reads; its production component source remains unchanged from d688. The preview directory preserves that separate manifest and captures. This still does not prove native preview pixels.

## Preserved source and capture limits

[source-snapshot.json](source-snapshot.json) maps the relevant historical scenario, component and style files to content-addressed copies, independent of transient branch references. This is not a complete build snapshot. The old preview-unavailable screenshot was captured after Playwright scrolled to its button; its displaced sticky rail makes it unsuitable as a complete layout proof. The current capture helper resets page scroll before capture, but no new browser run is claimed by this correction.
