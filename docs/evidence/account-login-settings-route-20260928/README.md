# Account login on the dashboard settings route

Source revision: `7a364e00280ced36265b914e9057584a5584f42b`.

The browser loaded the real dashboard application entry at `/dashboard/#settings?section=runtime` through Vite. `SettingsSurface` rendered `OnboardingSettings`, which rendered the account/model picker from fetched setup inventory. This run does not use the standalone development fixture page.

HTTP responses were isolated browser mocks. No provider was authenticated and no production configuration was changed. Unrelated runtime/config/transport panels are outside the mock scope and can show unavailable observations. These captures prove production-route reachability and browser behavior, not deployed-binary or live-authentication behavior.

`results.json` records the source revision, actual route, and model discovery/save request references. The four flows cover Codex/Claude at 1280px and Antigravity/Muse at 390px; every model save uses the logged-in account reference. Claude drops the completion frame and recovers from the receipt endpoint. Antigravity cancels, checks its receipt, and retries the retained account. Screenshots include route context and the complete login panel, including the mobile code-entry and cancellation controls. No horizontal overflow or browser page errors occurred.

Validation at the source revision:

- 101 Vitest assertions/tests passed across seven suites: setup-login API; onboarding; login panel; login/picker flow; existing picker behavior; resume control; and the actual settings surface.
- TypeScript `tsc --noEmit` passed.
- The settings surface test emitted a handled localhost:3000 sandbox network warning while all assertions passed; this is not a clean network-log claim.
- Playwright passed all four actual-route flows, cancellation/retry, lost-completion recovery, secret-storage checks, and viewport checks.

Reproduce after installing dashboard dependencies:

```sh
MASC_DASHBOARD_PROXY_TARGET=http://127.0.0.1:9 pnpm --dir dashboard exec vite --host 127.0.0.1 --port 5297 --strictPort
SETUP_LOGIN_FIXTURE_URL='http://127.0.0.1:5297/dashboard/#settings?section=runtime' SETUP_LOGIN_ARTIFACT_DIR=/tmp/setup-login-settings-evidence pnpm --dir dashboard exec node e2e/setup-account-login.mjs
```
