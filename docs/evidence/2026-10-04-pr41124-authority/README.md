# Lane draft authority and explicit comparison adoption

Baseline #41124 head `10e6a16cd13c394cfd5474115f73d16087e69a22`.
The repair was integrated with parent #41122 `4f50f04a29c09f7ec6b0aace326933a5be2bd652`.

Three UI regressions failed before the repair: idle retained draft after A→B→A,
after A→unavailable→A, and Save after comparison without adopting its revision.
On a new authority token, retained text remains but old comparisons are cleared
and saving requires a fresh read. Reading a comparison does not adopt it; the
explicit revision action does. The request uses that chosen revision. Existing
pending-read/write authority assertions remain; the pending-write setup now
explicitly adopts its prior comparison before starting the write.

Integrated commands in dashboard:

```sh
pnpm test src/components/lane-declaration-editor.test.ts src/components/lane-addons-panel.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/lib/lane-declaration-sessions.ts src/components/lane-declaration-editor.ts src/components/lane-declaration-editor.test.ts src/components/lane-addons-panel.ts src/components/lane-addons-panel.test.ts
```

Vitest renders the actual components with mocked HTTP APIs. These results do not
claim an actual browser run, backend file writes, full CI, or release readiness.
Raw logs are retained unchanged, including trailing blank lines.
