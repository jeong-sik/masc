# PR41160 follow-up: authority retries and partial Settings refresh

Published baseline: `20cc51141851e3c3da45e9d9905a46cbe0ae8a45`.
Addresses review comments 4178056062 and4178056064.

A read retiring under a new authority now invokes ensure for the currently
accepted authority of the same workspace, after releasing its phase. This
preserves dirty text and lets the normal revalidation rules decide whether the
old revision is still usable. Foreign or unavailable authority is not retried.

The mounted Settings commit subscriber now invokes the existing four reload
helpers with its authority/generation/active publication guard. Each helper
applies its own success or clears/reports its own failure independently, so an
unavailable provider catalog no longer suppresses successful resolved/defaults
and raw-file snapshots. Unrelated callers keep their existing default behavior.

## Executed checks

- Two read regressions, clean and dirty, failed on the published baseline and
  passed with the repair. `red.log` records those two genuine failures. Its third
  failure was an initial Settings test setup mistake: parameterized cases reused
  a retired workspace epoch. That third result is not product RED evidence.
- After giving each parameter a distinct epoch, `settings-red.log` reran only
  the provider-failure case with published Settings production bytes and failed
  because the newly resolved model never appeared. The candidate bytes were
  restored in finally. The repaired test verifies the new model plus the catalog
  error and retains the original late-save/unmounted-editor assertions.
- Full two-suite result: 141 passed. Whole dashboard TypeScript and changed-file
  ESLint passed. No browser, native, backend, full-suite or release claim.

Commands from dashboard:

```sh
pnpm test src/components/runtime-toml-editor.test.ts src/components/settings-surface.test.ts
pnpm exec tsc --noEmit --pretty false
pnpm exec eslint src/lib/runtime-toml-session.ts src/components/runtime-toml-editor.test.ts src/components/settings-surface.ts src/components/settings-surface.test.ts
```

Logs preserve exact raw bytes, including EOF whitespace warnings. Earlier parent
integration evidence remains historical and byte-for-byte unchanged.
