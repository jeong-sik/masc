# Exact setup retry clears only its resolved error

Response to comment4179163353 on published #41172 `cf9635ecb077e83176de2bdedbf3028d2d6b77ae`. Automatic Exact setup failure now has its own `setupResumeError`, separate from the existing consumer-refresh `followupError`. The manual control passes its typed `ModelSetupResumeState` result to the Runtime callback. Only an active result from the still-current workspace authority clears the corresponding retained Exact setup errors. No error-string matching, file write, or blanket refresh-error clearing is used.

Actual component regressions drive the real manual control/Runtime callback and Exact panel with mocked transport boundaries. Before the fix, success and success-with-independent-refresh-error failed to clear the setup alert; failed-retry and changed-authority controls passed. The final tests also remount the activity panel and assert one original save only. The independent refresh error remains visible.

The first broader run exposed an ambiguous test locator because Runtime and the separately mounted Exact panel both showed the preserved refresh error, and an existing lower Settings assertion still targeted the old combined field. The locator now checks actual visible presence, and the Settings assertion explicitly checks the setup failure field. The failing run is retained rather than relabeled.

Final actual result: **198 tests in four suites PASS**, TypeScript and changed-file ESLint report zero errors. Commands from dashboard:

```sh
node node_modules/vitest/vitest.mjs run src/components/exact-lane-activity-panel.test.ts src/components/runtime-toml-editor.test.ts src/components/model-setup-resume-control.test.ts src/components/settings-surface.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1
node node_modules/typescript/bin/tsc --noEmit
node node_modules/eslint/bin/eslint.js src/lib/exact-lane-activity-session.ts src/components/exact-lane-activity-panel.ts src/components/exact-lane-activity-panel.test.ts src/components/model-setup-resume-control.ts src/components/runtime-toml-editor.ts src/components/settings-surface.test.ts
```

The behavioral RED used the Exact suite with `-t 'settles only the resolved setup error'` (handle86927 exit1). Initial broader run24574 contains the two fixture integration failures. Final combined run99197 exited0. Raw logs retain exact bytes and EOF whitespace. Source and artifact hashes are recorded in checks.json. No browser, native, real server setup, provider, CI or release execution is claimed. This is introducing-owner qualification, not a downstream aggregate substituted for lower tests.
