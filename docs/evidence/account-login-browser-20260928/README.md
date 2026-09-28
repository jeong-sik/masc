# Account login browser evidence

Source revision: `58a15239f965e758508626d89003c6cc5f28a648`.

The isolated Vite fixture renders the production setup picker and login panel with intercepted HTTP responses. It does not authenticate a live provider or modify production configuration. `results.json` records the account references sent to model discovery and save. Screenshots cover desktop Codex/Claude and mobile Antigravity/Muse, before and after save. Cancellation/retry and lost completion recovery are asserted by `dashboard/e2e/setup-account-login.mjs`.

Reproduce by serving the dashboard with its backend proxy pointed at an unused local port, then run `SETUP_LOGIN_FIXTURE_URL=http://127.0.0.1:5297/dashboard/dev-fixtures/setup-account-login-fixture.html SETUP_LOGIN_ARTIFACT_DIR=/tmp/setup-login-evidence pnpm --dir dashboard exec node e2e/setup-account-login.mjs`.

Production-route reachability is now verified separately in [the settings-route evidence](../account-login-settings-route-20260928/README.md). This earlier folder proves the standalone component fixture only.
