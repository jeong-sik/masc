# Keeper Item tab browser fixture

These screenshots show the Item tab in a Vite/Playwright browser fixture at PR #40033. The fixture serves an authenticated-shape `ready` account for `rondo` with 0.800 Candle, one purchased crown, and 18 catalog entries. The portrait PNG request deliberately returns 503, so the fallback badge is visible. This proves browser rendering and 360px layout of the new tab; it does not prove live-server rollout or a real Keeper ledger.

Reproduce from `dashboard/` after installing dependencies:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:1 pnpm exec vite --host 127.0.0.1 --port 5197 --strictPort
KEEPER_ITEMS_FIXTURE_URL=http://127.0.0.1:5197/dashboard/dev-fixtures/keeper-items-fixture.html KEEPER_ITEMS_ARTIFACT_DIR=/tmp pnpm exec node e2e/keeper-items.mjs
```
