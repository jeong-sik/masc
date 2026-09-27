# TOML table identity browser regression

Synthetic data, rendered with the production `RuntimeExactLaneEditor` component.

- Before: provider table `[providers . "p"]`, deadline `10`.
- Interaction: change the deadline input to `15`, then blur.
- After: the same header and inline comment remain; no `[providers.p]` table is appended.
- Chromium reported no page errors. `browser-result.json` contains the resulting source.

From `dashboard/`, start `MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 pnpm exec vite --host 127.0.0.1 --port 4187 --strictPort`, then run `node evidence/toml-identity/verify.mjs http://127.0.0.1:4187/dashboard/`.
The fixture makes no server API calls and proves browser editing only, not deployed configuration or restart behavior.
