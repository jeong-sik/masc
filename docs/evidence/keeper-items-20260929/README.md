# Keeper Item tab browser fixture

These screenshots show the Item tab in a Vite/Playwright browser fixture at PR #40033. The fixture serves an authenticated-shape `ready` account for `rondo` with 0.800 Candle, one purchased crown, and 18 catalog entries. The portrait PNG request deliberately returns 503, so the fallback badge is visible. This proves browser rendering and 360px layout of the new tab; it does not prove live-server rollout or a real Keeper ledger.

Reproduce from `dashboard/` after installing dependencies:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 pnpm exec vite --host 127.0.0.1 --port 5197 --strictPort
KEEPER_ITEMS_FIXTURE_URL=http://127.0.0.1:5197/dashboard/dev-fixtures/keeper-items-fixture.html KEEPER_ITEMS_ARTIFACT_DIR=/tmp pnpm exec node e2e/keeper-items.mjs
```

## Workspace authority repair

The archived desktop/mobile PNGs above predate the workspace repair and are not current-head proof. The account now consumes the accepted execution workspace authority, withdraws account/error rows on unknown identity or reconnect, and rejects old success/failure callbacks across A/B/A even when Keeper name, outfit and wallet stay identical. This core fix is adapted from the later #40190 unit into #40033 so the open P2 is resolved before approving this lower layer.

The repair was checked with `pnpm exec tsc --noEmit` and the Item API/component Vitest suites (9 passing tests). The real Preact component was also exercised through the local Vite/Chromium fixture with `e2e/keeper-items-workspace.mjs`: A/B/A, a held old-A response, current-A recovery and unknown-root withdrawal passed, with 8 screenshots and no page errors. These are synthetic browser results, not installed runtime, live ledger or CI proof. The first browser attempt encountered a Vite dependency-optimization reload and did not pass; the warmed-server rerun passed.

Reproduce the workspace scenario with the same fixture server URL:

```sh
KEEPER_ITEMS_FIXTURE_URL=http://127.0.0.1:5197/dashboard/dev-fixtures/keeper-items-fixture.html KEEPER_ITEMS_ARTIFACT_DIR=/tmp pnpm exec node e2e/keeper-items-workspace.mjs
```
