# Onboarding retry completion

Exact #41172 baseline8a28d51ab930cff9f173f8b691c40b8307c5230c; review comment4179480231. Onboarding used ModelSetupResumeControl without the typed completion callback already used by Runtime. A successful retry therefore left a retained Exact activity session's setupResumeError visible.

The production change captures the rendering workspace authority and forwards the typed completion result through completeExactLaneSetupResume. The existing session method clears only setupResumeError for an active result and matching current authority. Failed retries, A→B→A late completions, and independent refresh failures remain protected. No model resume API or automatic-save behavior was changed.

The existing actual activity-session/component retry matrix now covers both Runtime and Onboarding. Onboarding success and refresh-error variants reproduced the stale setup error (2 failures); failed-retry and authority-change controls passed. After wiring the callback, the broader run passed142 tests but the onboarding suite failed import because its full api/core mock omitted a newly imported real export. The mock now preserves actual exports while retaining mocked GET/POST; no assertion was removed.

Final command: `pnpm --dir dashboard test src/components/exact-lane-activity-panel.test.ts src/components/onboarding-settings.test.ts src/components/model-setup-resume-control.test.ts src/components/runtime-toml-editor.test.ts` —146 tests across4 suites PASS. `pnpm exec tsc --noEmit --pretty false` and ESLint on the three changed TS files passed. Raw initial RED and mock-setup failure are retained separately. No browser/native/full suite, CI, release or TerminalBench result is claimed. No commit or push performed by this response owner.
