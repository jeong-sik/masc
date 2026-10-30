# Dashboard Candle and Portrait decoding boundary

This is a source candidate. No local typecheck, build, Vitest, browser run or native test was performed. Syntax checks and unchanged source comparisons do not prove the emitted bundle or a working screen.

## Provenance and observed failure

The actual child publication parent is `9464d7404c97b086d1b5cdc7af2c817e8f5d23cc` (#40190). Its Item feature composition parent is `a065328066d9996f8658238e3077cad70c2c063c`.

The local parent is `a215894965a620af1ba80d6c464eb6e082e4e423`. It contains a partial import of the actual feature parent plus the Item authority changes. Publish only the new child delta over that local parent onto the actual API parent; publishing the local whole tree would lose unrelated files from the actual parent.

The retained parent run `36675841756`, job `109760501265`, checked out `a065328066d9996f8658238e3077cad70c2c063c`. Nine preceding activation/UI suites passed (442 cases). The production bundle suite then had one failure and two passes: `dashboard-bundle-preload.test.ts:152` expected the initial static chunk closure to contain no Effect modules, but found one. These are results for the parent, not this candidate. `parent-bundle-job.log.gz` retains the raw job log; `parent-bundle-failure.json` records its hashes and scope.

## Source cause and change

Initial loading reaches Effect through `app → store → candle-observation` and through `keeper-store-normalize → keeper-portrait/candle-observation`. Common normalizers also import the Keeper module for pure phase/trust helpers, so deferring only the store import would leave eager dependencies.

The two observation domains now decode their closed wire values without importing Effect:

- Candle requires the exact envelope fields, canonical decimal strings and exact `BigInt` conservation. Every raw roster row must agree with the envelope. `null` remains the explicit Off/Disabled balance; missing or malformed values remain unavailable. Sparse rows cannot disappear from validation. Decimal formatting still avoids JavaScript `Number`.
- Portrait derives its equipment type and validation from the existing slot vocabulary. Ready equipment is complete, belongs to the correct slot, and has no extra fields. A producer-declared unavailable reason is preserved; malformed data receives the explicit unavailable observation.
- Both readers return detached frozen projections. The strict Portrait predicate is also the only Portrait validator used by the lazy Gate decoder through Effect v3 `Schema.declare`. Gate malformed data produces its typed schema drift error; it does not pass through the observation reader's unavailable result.

The old amount regex could match before a final line terminator. Matching the complete input now rejects LF, CR and Unicode line separators as noncanonical monetary bytes.

This is closed domain validation, not a generic replacement schema framework. It reuses the repository's record guard and canonical equipment vocabulary. Effect remains the existing library for the lazy Gate/Item API boundaries, and its installed v3.22.1 type declaration explicitly supports `Schema.declare(typePredicate)`. No dependency or schema framework was added, and no second Portrait validation implementation was introduced.

The construction-only Effect schemas were removed. The first published child also removed `readCandleAccountRevision`, which still had a consumer in `keeper-store-normalize.ts`; the later repair restores that pure decoder. Store hydration remains synchronous. Workspace tokens, publication epochs, connection generations, HTTP/SSE admission, Item account revisions, browser fixtures, Vite configuration and the production bundle assertions are unchanged.

## Verification and remaining gate

`source-checks.json` records Node v26.3.0 syntax checks for the six changed TypeScript files and `git diff --check`, all exit 0. `composition.json` records the parent identities and thirteen paths compared against the partial local parent. Twelve of those hashes match the first published child, but the published `keeper-store-normalize.ts` differs and still imports the revision decoder. These local comparisons are not proof that every published consumer was retained. `source-checks.json` and `source-sha256.json` describe the historical candidate, before the revision repair.

`source-boundary.json` derives the local static source closure from the preceding source graph with the two changed imports. Its reachable Effect import sources go from two to zero. This is an import approximation on a partial local tree, not Rollup output and not proof for the full published tree.

The new regression source covers exact field sets, canonical monetary bytes, aggregate precision/conservation, roster balance agreement, complete equipment, immutable observations, preserved unavailable detail and typed Gate drift. These tests have not run locally.

Final publication requires current-head CI, including the unchanged production bundle contract. Relevant test selectors are:

```text
src/dashboard-bundle-preload.test.ts
src/api/schemas/candle-observation.test.ts
src/api/schemas/keeper-portrait.test.ts
src/api/schemas/gate-keepers.test.ts
src/api/gate-keepers.test.ts
src/keeper-store-normalize.test.ts
src/components/candle-economy.test.ts
src/components/keeper-portrait.test.ts
src/components/keeper-items-panel.test.ts
```

The Item workspace browser scenario still needs an actual CI-produced preview and retained browser evidence. This source candidate makes no browser, release or production claim.

## Assigned publication

At its first publication, PR #40241 stacked the child delta over #40190 head9464d7404c97b086d1b5cdc7af2c817e8f5d23cc. No placeholder changelog was published. The numbered40241 fragment and source hash manifest replace the local placeholder; the six source/test files at headfc5bb8afc5cfe2a25a74fa70afc3a2477cc04337 were byte exact to the reviewed fdf9dff9 candidate. This is source parity, not typecheck, Vitest, bundle or browser evidence.

## Published-child link failure and repair

Dashboard run `36684106255` at `fc5bb8afc5cfe2a25a74fa70afc3a2477cc04337`
failed with Rollup's missing `readCandleAccountRevision` export, before the
intended production-bundle assertions or requested feature/browser checks
could pass. The published normalizer's existing import was absent from the
partial local comparison. The repair restores the decoder without importing
Effect and tests exact lowercase 64-byte hex, explicit null, missing/malformed
values and trailing line separators. The historical receipts above are kept;
they do not certify these repaired files. New current-head bundle, feature and
browser execution remains required.
