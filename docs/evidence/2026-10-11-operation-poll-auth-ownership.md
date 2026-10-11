# Operation polling ownership across authentication changes

Three deferred lookup cases directly failed before repair: an old-auth terminal receipt mutated recovery and started history reconciliation; an old-auth failed lookup overwrote the current action error; and a pending old-auth lookup prevented current-auth recovery from starting.

Recovery now owns an exact map entry with the admitted stored-token revision. It checks that ownership before polling, after lookup resolution and before handling lookup failure. A current-auth attempt can replace an old-auth owner. The older attempt's finally only releases its own map entry and cannot clear a replacement's activity. Composite keys encode the keeper and operation structurally.

Four behavioral cases cover old lookup success/failure, overlapping owner replacement with duplicate-admission suppression, and an authentication change during queued polling sleep. The latter checks that old recovery cannot issue another request using newly installed credentials, and current-auth explicit retry still receives its cancellation receipt.

This scope preserves stored observations and tracking. It does not establish complete cached-transcript/account isolation, live-send stream admission, provider execution or rendered screenshots. The full chat goal remains active.

Validation: `pnpm exec vitest run src/keeper-actions.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1` passed 96 tests. `pnpm exec tsc --noEmit` and `git diff --check` passed. The first independent source review found no unresolved P0–P2 in the product/test diff.
