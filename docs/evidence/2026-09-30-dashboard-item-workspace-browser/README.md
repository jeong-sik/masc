# Item workspace browser fixture

This is a real Chromium run of a CI-built controlled fixture. All Item account replies are synthetic. It is not a production runtime or wallet transaction, and it does not prove the later #40241 decoder or Item amount child (`fc5bb8af…` / `d2cb…`).

## Build and execution provenance

| Field | Recorded value |
| --- | --- |
| PR | #40190 |
| PR head | `9464d7404c97b086d1b5cdc7af2c817e8f5d23cc` |
| Actual CI checkout | `8721039c55adf410df3eb08ac8366a63a8b3a65e` |
| Checkout tree | `0d5b605d2a75fd9e7dff43f74db4bf2c9bbaca5d` |
| CI run / attempt | `36680267722` / `1` |
| Recorded typecheck job | `109776186663`, success |
| Execution environment | Apple container 1.3.1; Linux amd64 Rosetta microVM |
| Browser image | `mcr.microsoft.com/playwright:v1.61.1-noble` |
| Browser | Chromium `149.0.7827.55` |
| Scenario result | Exit 0; 8 screenshots; 4 account reads; 0 page errors |

The build identity names the actual checkout, not the PR head. [The retained source comparison](ci-checkout-source-delta.json) reports the checkout two commits ahead, with eight changes confined to TUI/bin/test/changelog paths. There are no Dashboard or Dashboard build-input changes in that receipt, so the relevant Dashboard source inputs match the PR head. This is source parity, not a claim that the whole checkout equals the PR head.

[CI preview provenance](ci-preview-provenance.json) retains SHA-256 values for 690 artifact files. A local read-only audit matched all 690 files to the recorded hashes and checked the build identity. These hashes cover the artifact inventory; they do not mean the browser requested every file.

[The retained runner](workspace-ci-preview.mjs) adds only static delivery to the existing workspace scenario. It fulfills requests with the verified CI asset bytes through Playwright interception. Its API routes, synthetic replies, assertions and screenshots match the original scenario. [Static delivery provenance](static-delivery-provenance.json) records both runner hashes and the preview path. No repository build or local HTTP server was run for this delivery. The earlier host macOS browser attempt closed before the scenario; only the Linux microVM run is evidence.

The image index and amd64 manifest digests are retained in [runtime provenance](runtime-provenance.json).

## Observed account behavior

The Keeper (`rondo`), wallet (`800` millicandle), outfit (`crown`) and project label remain fixed. Workspace roots and scoped ownership/catalog observations change:

| Read | Controlled observation | Owned items | Crown price |
| --- | --- | --- | --- |
| 1 | Initial A | crown | 200 millicandle |
| 2 | Held A refresh | crown, beanie, book | 900 millicandle |
| 3 | B | crown, beanie | 300 millicandle |
| 4 | Current A after return | crown, beanie, book, mug | 400 millicandle |

The scenario withdraws A's loaded account during refresh, shows B's ownership/price, withdraws B when returning to A, and keeps the old held A values absent. Current A then shows its fresh values. Removing workspace authority shows the explicit workspace-loading state and withdraws the account without a fifth read.

[The workspace manifest](workspace-manifest.json) records one `requestfailed` event with `net::ERR_ABORTED`. The held route's `fulfill` call returned. This proves ordinary browser transport cancellation and the observed UI sequence; it does **not** prove that a JavaScript promise ignored `AbortSignal` and resolved. That separate component-test behavior needs its own executed-suite evidence. The zero error count refers to recorded `pageerror` events.

## Screenshots

These are full-page PNGs. The listed dimensions are the browser viewport; full-page image height can be larger. Every PNG hash matches its capture entry in the manifest.

| State | Desktop viewport | Mobile viewport |
| --- | --- | --- |
| Initial A: 1 owned, crown 0.200 Candle | [1280×900](keeper-items-workspace-a-desktop.png) | [360×844](keeper-items-workspace-a-mobile.png) |
| B: 2 owned, crown 0.300 Candle | [1280×900](keeper-items-workspace-b-desktop.png) | [360×844](keeper-items-workspace-b-mobile.png) |
| Returned A, fresh read still loading | [1280×900](keeper-items-workspace-a-return-loading.png) | — |
| Current A: 4 owned, crown 0.400 Candle | [1280×900](keeper-items-workspace-a-current-desktop.png) | [360×844](keeper-items-workspace-a-current-mobile.png) |
| Unknown workspace, account withdrawn | — | [360×844](keeper-items-workspace-unknown-mobile.png) |

The Portrait endpoint deliberately replies 503 in this account fixture, so the shown avatar fallback is not Portrait image-generation proof. Workspace updates affect only the fixture's window API. No live workspace, wallet or Goal was changed.

## Integrity

`SHA256SUMS` covers every retained file in this directory except itself, including this README and the untouched input artifacts. It can be verified with `sha256sum -c SHA256SUMS` from this directory. This evidence does not replace current-head required checks, production bundle verification or release/deployment evidence.
