# Current Item browser behavior and installed boundary

Source: `d688917369e608765472b63f6a2c307b42a66b90` (#40288).

Two real Chromium scenarios ran against that unchanged source's production Item components and CSS through a local Vite development server. Account HTTP data and roster/workspace observations were synthetic. The portrait endpoint deliberately returned 503: the screenshots show the badge fallback and do not prove native PNG rendering.

- Account scenario: seven screenshots cover desktop/mobile, pending read withdrawal, free ownership change, price-only change, failed read and recovery. Five account reads completed; no uncaught page errors.
- Workspace scenario: eight screenshots cover fixed Keeper/wallet/outfit across A→B→A, held old response release, current response, and unknown workspace withdrawal. Four scoped reads completed; no uncaught page errors. Browser abort outcomes are recorded without claiming an aborted JavaScript promise was forced to resolve.

The first cold attempt was displaced by Vite's dependency optimization and page reload. Its account count was six and the workspace scenario timed out at its first account wait. The Vite log confirmed the reload. Both unchanged scenarios then passed on the same server after optimization; the failed attempts are not silently counted as passes.

## Installed observation

Read-only health identified installed server version 0.49.0, embedded commit `4f3f70f7909bc440e3c305c0941250ef39ac0245`, readiness true. Its real roster listed 27 Keepers, but an authenticated Item read for `code-reviewer` returned HTTP 404. That source's main tree contains neither the Item route nor the TUI Items tab. An installed TUI version of 0.49.0 alone does not identify its source commit.

This proves the tested frontend fixture behavior and the installed route gap. It does not prove current-head native purchase/equip/restart behavior, native PNG output, an installed Items screen, or release readiness. No build, CI, install, runtime restart, purchase or configuration change was performed.

Hashes and exact source/runtime provenance are in [receipt.json](receipt.json). Original scenario manifests are retained in the account and workspace directories.

A repeated authenticated HTTP observation is retained in [installed-http-observation.json](installed-http-observation.json): exact Item response status/body and readiness response, plus selected health/build/path fields. Request credential values and dev-token responses are omitted. The observation has its own timestamp and build identity.

## Preview failure and restoration

Scenario source `05044d48a75b1e3036e14210990fe4ec04362edf` adds Chromium clicks for the unowned beanie preview. The mocked 503 PNG produces the explicit preview-failure alert. Returning to the observed outfit removes the alert and selection while preserving the real displayed account observation. The expanded scenario passed with nine screenshots and five account reads; its production component source remains unchanged from d688. The preview directory preserves that separate manifest and captures. This still does not prove native preview pixels.
