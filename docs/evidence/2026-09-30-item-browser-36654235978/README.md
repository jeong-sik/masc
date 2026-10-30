# Item browser transition proof

CI run: https://github.com/jeong-sik/masc/actions/runs/36654235978
Source: `6f4eb0dabeb7f4ddbb441ef49561085aa60a40f0`.

Every workflow step completed SUCCESS, including the unchanged production bundle contract, focused feature tests, Chromium scenario and production bundle packaging.

The real production Item panel ran in a controlled Vite/Chromium fixture with synthetic account HTTP responses and roster revisions. Seven screenshots capture desktop, 360px mobile, held-response loading, a free glasses purchase, a price-only crown change, failed account read and recovery. The browser made five account reads and reported no uncaught page error. Screenshot hashes are verified against the downloaded manifest.

The loading and error states withdraw the old account. Free ownership and price changes leave wallet/outfit fixed. The portrait endpoint deliberately returns 503, so the badge fallback is visible; these screenshots do not prove a real PNG endpoint, live server or operator deployment. The initial failure screenshot retains the then-current API-path wording; a later UI change makes that error reason readable without the internal endpoint.

Later changelog or wording changes require their own current-head checks. This is evidence for the cited source, not a whole-stack merge or deployment receipt.
