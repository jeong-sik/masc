# Nested JSON readings

At original head `1110d7d150410e189b9bcf468cdeb686fe9f965a`, a real
JSON.parse-to-decoder-to-component regression rendered rounded counts in
objects, nested arrays and JSON scalars. Numeric overflow rendered as null.
The recorded RED contains these incorrect displayed values.

The JSON reading now validates numbers recursively before serialization.
Unsafe integers and nonfinite numbers remain unavailable; safe integer
boundaries, fractions, zero, strings, null and booleans retain their values.
The affected panel/editor suites passed 42 tests after the fix. Whole
Dashboard TypeScript and changed-file ESLint passed with no diagnostics.

Commands from dashboard:

```sh
pnpm test src/components/lane-addons-panel.test.ts -t 'refuses rounded or nonfinite numbers anywhere in JSON readings'
pnpm test src/components/lane-addons-panel.test.ts src/components/lane-declaration-editor.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/components/lane-addon-readings.ts src/components/lane-addons-panel.test.ts
```

The full test invocation also named src/api/lane-addons.test.ts, which does
not exist. Vitest ran the two existing suites shown in green.log; no API suite
result is claimed. No browser rerun, backend, full CI or release verification.
Raw logs and their EOF whitespace are preserved unchanged.
