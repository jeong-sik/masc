# Unbound publication ownership is not a wildcard

Base: `da75be090643384f1f813f7f3e81042b8b632834`.

The existing publication-owner predicate treated a captured absent delivery key as permission to update any subsequently identified operation. A real Preact signals observer replaces a live row during Thinking flush, keeping the same row ID, runtime ID and attempt index but introducing another operation's delivery identity. The original retry then incorrectly changes the replacement to retrying.

Executed targeted `keeper-stream.test.ts` test selection `-t 'replaced operation from'` against the base with the expanded fixture: exit 1, one known-owner case passed, unbound-owner case failed, 127 skipped. Failure: expected opening, received retrying. This uses synthetic operation/frame data but actual reactive state publication.

The correction makes absent ownership symmetric: an absent captured delivery key remains valid only while current delivery provenance is absent. Known keys still require exact typed equality. Existing credential, source and turn checks remain. No alternate owner registry or content classification is introduced.

Executed final checks from dashboard:

- `vitest run src/keeper-stream.test.ts --config vitest.config.ts --no-file-parallelism --maxWorkers=1`: exit 0, 129 tests, 838 ms.
- `tsc --noEmit`: exit 0.
- `git diff --check`: exit 0.

These prove the exercised state/publication boundary only. No local build, CI, provider execution, installed application or screenshot evidence. A newly identified operation requires a fresh observation rather than inheriting an unbound deferred publication.
