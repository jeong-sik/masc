# Item monetary amount source candidate

No local typecheck, build, Vitest, native test or browser run was performed. Syntax and source checks do not prove runtime or screen behavior.

## Provenance

This child depends on #40241's strict Candle amount predicate. Its actual publication parent is `fc5bb8afc5cfe2a25a74fa70afc3a2477cc04337`; the local parent is `3b6652a909723a2b66a4bfcb4ba92032896fbc80`.

The local checkout retains the partial Dashboard feature snapshot used by #40241. Overlay only this new child delta onto the actual publication parent. The local whole tree is not a complete publication baseline.

## Defect and repair

The lazy Item schema duplicated the former decimal regex with `.test()`. JavaScript's `$` can match before a final line terminator, so a balance or catalog price such as `200\n` could pass and reach decimal formatting with invalid bytes.

The existing pure `isCandleAmount` predicate is now exported with its millicandle domain contract. The Item amount schema calls it through its existing Effect `Schema.filter` and retains the same explicit schema drift error. There is one canonical amount grammar; no parser facade, library, new module, formatting policy or wallet mutation was added.

The public `parseKeeperItems` regression source checks LF, CR, CRLF and both Unicode line separators in the wallet and priced catalog. It also checks that explicit price `0` remains priced, a book remains unpriced, and large canonical balance/price strings survive exactly beyond machine integer ranges. Existing identity, catalog, malformed-value and ownership tests remain intact.

## Verification scope

`source-checks.json` records syntax checks for the three changed TypeScript files, whitespace validation and the changelog fragment check. `composition.json` records their source identity and unchanged Item account, workspace, browser and bundle boundaries. `source-sha256.json` hashes the candidate files.

Required current-head CI selectors include `src/api/keeper-items.test.ts`, `src/api/schemas/candle-observation.test.ts`, `src/components/keeper-items-panel.test.ts` and the unchanged `src/dashboard-bundle-preload.test.ts`. The held A/B/A account and free-purchase/reprice scenarios are unchanged. Current-head CI and actual browser evidence remain required; this document makes no runtime, release or production claim.

## Assigned publication

PR #40252 overlays only this reviewed delta on actual #40241 headfc5bb8afc5cfe2a25a74fa70afc3a2477cc04337. No placeholder fragment was published. The three source/test files remain byte identical to reviewed2dbbc6e; the40252 fragment and manifest replace local placeholder data. Source parity is not a current typecheck/test/browser result.
