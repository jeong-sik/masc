# Item monetary amount source candidate

No local typecheck, build, Vitest, native test or browser run was performed. Syntax and source checks do not prove runtime or screen behavior.

## Provenance

This child depends on #40241's strict Candle amount predicate. Its actual publication parent is `fc5bb8afc5cfe2a25a74fa70afc3a2477cc04337`; the local parent is `3b6652a909723a2b66a4bfcb4ba92032896fbc80`.

The local checkout retains the partial Dashboard feature snapshot used by #40241. Overlay only this new child delta onto the actual publication parent. The local whole tree is not a complete publication baseline.

## Shared validation

The lazy Item schema duplicated the canonical decimal regex with `.test()`. Without multiline mode, that predicate already rejects LF, CR, CRLF, U+2028 and U+2029 suffixes. This change removes duplicated validation; it does not repair a line-terminator acceptance defect.

The existing pure `isCandleAmount` predicate is now exported with its millicandle domain contract. The Item amount schema calls it through its existing Effect `Schema.filter` and retains the same explicit schema drift error. There is one canonical amount grammar; no parser facade, library, new module, formatting policy or wallet mutation was added.

The public `parseKeeperItems` tests preserve rejection of LF, CR, CRLF and both Unicode line separators in the wallet and priced catalog. These cases also pass with the previous predicate and are not evidence of a repaired defect. The tests also check that explicit price `0` remains priced, a book remains unpriced, and large canonical balance/price strings survive exactly beyond machine integer ranges. Existing identity, catalog, malformed-value and ownership tests remain intact.

## Verification scope

`source-checks.json` records syntax checks for the three changed TypeScript files, whitespace validation and the changelog fragment check. `composition.json` records their source identity and unchanged Item account, workspace, browser and bundle boundaries. `source-sha256.json` hashes the candidate files.

Required current-head CI selectors include `src/api/keeper-items.test.ts`, `src/api/schemas/candle-observation.test.ts`, `src/components/keeper-items-panel.test.ts` and the unchanged `src/dashboard-bundle-preload.test.ts`. The held A/B/A account and free-purchase/reprice scenarios are unchanged. Current-head CI and actual browser evidence remain required; this document makes no runtime, release or production claim.

## Assigned publication

At first publication, PR #40252 overlaid this child delta on #40241 headfc5bb8afc5cfe2a25a74fa70afc3a2477cc04337. No placeholder fragment was published. The three source/test files at d2cb2f795b9939fb7428c04392cad754e2fe4ed8 were byte identical to reviewed2dbbc6e; the40252 fragment and manifest replaced local placeholder data. This historical source parity is not a current typecheck/test/browser result.

## Parent repair integration

Dashboard artifact run `36689030636` failed at published child `d2cb2f795b9939fb7428c04392cad754e2fe4ed8`: Rollup could not resolve `readCandleAccountRevision`, still imported by the actual Keeper normalizer. The integration includes parent repair `5be8d8fc35164915a3507898ce6fde117f379bb6` from #40241 through a merge, without duplicating its implementation. The strict amount export and Item regressions remain intact.

The original `source-checks.json`, `composition.json`, and `source-sha256.json` are historical source receipts, preserved byte for byte. Before integration, all seven manifest file hashes matched the child, but only sixteen of the seventeen local-parent boundary hashes matched the actual publication tree: the normalizer differed, as already documented for #40241. After integration, the Candle schema includes the restored revision export and this README and changelog include the integration note; their original manifest hashes no longer describe the current files. The historical receipt does not establish current-tree identity or native success.

Current-head Dashboard artifact verification must cover the production bundle contract, Item public parser, Candle observation parser, Item panel, and workspace authority. Local syntax and pure predicate controls are separate from those native results and from browser or production evidence.
