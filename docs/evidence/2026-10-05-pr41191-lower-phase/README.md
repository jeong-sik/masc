# PR #41191 lower-phase

Starting published head `a6141d9787a4f7f7b48be6bb3c531cd8f655b178`.

The Browser receipt-held Settings regression belongs to this introducing owner. Its three parameterized cases expected saving after the verified receipt although the session now correctly reports followup. Only that exact phase assertion changes; receipt, fresh projections, held refresh and no-extra-POST assertions remain.

Actual lower-owner full Settings suite RED:3failed/60passed, each at expected saving vs actual followup. GREEN:63passed, TypeScript and scoped ESLint passed. RED includes failed-fetch ECONNREFUSED output during aborted fixture cleanup; GREEN has no such warning. This does not rely on the later41194 leaf expectation or a combined-leaf PASS.

Commands from dashboard: pnpm test src/components/settings-surface.test.ts; pnpm exec tsc --noEmit; pnpm exec eslint src/components/settings-surface.test.ts.

Execution is local mocked-HTTP component/API evidence only, not browser/native/provider/full-suite or final-chain proof. Raw logs are tracked byte-exact; hashes are in checks.json.
