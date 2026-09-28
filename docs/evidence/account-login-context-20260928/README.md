# Documented context entry on production settings

Source revision: `9210d531ef16498e07cdc10770356d807d78143d`.

The real dashboard route `/dashboard/#settings?section=runtime` was driven with isolated browser API mocks. No real provider authentication or production configuration was exercised. Codex and Claude returned models with absent context metadata; the operator entered a documented example value of 123456 tokens and the same value and account reference reached the verified-save request. No unsupported context-preparation request was made for those clients. Antigravity and Muse retained their existing native metadata paths.

The browser scenario completed all four clients, including mobile layouts, cancellation/retry and lost completion recovery. `results.json` contains the route, source revision and observed model/save payloads. Screenshots capture the real settings page, login panel, context entry and saved state. Focused tests for this change: 30 passed; TypeScript typecheck passed before the exact-revision browser run.

Reproduction follows `../account-login-settings-route-20260928/README.md`, using the current `dashboard/e2e/setup-account-login.mjs` scenario. Provider responses remain mocks; these captures are browser integration evidence only.
