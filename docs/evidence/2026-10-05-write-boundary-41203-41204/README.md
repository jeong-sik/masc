# Reviewed write-boundary parent integration

Actual parent merges preserve Machine typed known-save refusal and Browser ASTMap parsing. This combined leaf executes 373 tests in seven Web suites, TypeScript and scoped ESLint successfully. Logs are copied byte-for-byte. Tests cover raw receipt/source invalidation, Exact/Browser/Machine refusal and concurrent invalidation, Settings refresh, and Browser parser round trips.

Command from dashboard: `pnpm test src/lib/browser-lane-activity.test.ts src/lib/machine-lane-activity.test.ts src/components/exact-lane-activity-panel.test.ts src/components/runtime-toml-editor.test.ts src/components/browser-lane-activity-panel.test.ts src/components/machine-lane-activity-panel.test.ts src/components/settings-surface.test.ts`; `pnpm exec tsc --noEmit`; scoped ESLint on the changed sessions/parser and corresponding component tests. Exact identities and hashes are in checks.json.

Native bin/lib/test bytes equal each prior published head, so no native rebuild or PTY run occurred. Prior native proof remains scoped to unchanged source. This is combined Web consumer evidence, not separate executions of both PR heads, provider execution, full regression, release or TerminalBench proof.
