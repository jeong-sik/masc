# Item account import reconciliation (#40252)

## Source composition

The dependent Item schema imports the existing synchronous domain `isCandleAmount` directly from `../../lib/candle-observation`. This is the only production change relative to the supplied exact c46 Item schema. The amount grammar, Effect schema filter, schema drift errors, catalog/identity/ownership checks, and public parser behavior retain their existing source bytes.

Root assigned actual publication parent `49aae5c7c32bf338792b95d55a98a1db1d86ef69`, tree `560ff5754b66879bee211bab8341dec0377084dd`. Its seven domain source/test files match immutable local code `292a406d98e127818af5f5e24bb1acd329692032`; lib Candle blob `1f72c67000292d5e03f90575710119c7faaf5a46` exports the unchanged canonical amount predicate. This child does not publish any Candle API/lib production delta or introduce a new amount predicate.

The isolated local clone imports the exact c46 Item schema, public parser tests, assigned fragment and historical README on local domain source parent `fd5e471b6f37743b89482286323ddec0b9f88da2`. This partial local tree is not the full actual publication baseline. Root composes the Item files onto the complete actual domain parent tree.

## Preserved source

The existing `src/api/keeper-items.test.ts` public parser regressions are byte identical to the supplied c46 API file, including line separators, explicit zero and large exact amounts. No additional tests were added. The historical Item README and its three original source receipt files remain unchanged. Their older source/build provenance remains historical; this new receipt does not rewrite those claims.

The seven domain code/test files are byte identical to the parent code commit. [composition.json](composition.json) records their Git blob and SHA-256 identities, the unchanged parser/receipt hashes and the one-line schema change.

## Verification limit

Node `v26.3.0` syntax-only `--experimental-strip-types --check` on the changed Item schema returned exit 0 with no output. `git diff --check` returned exit 0. Static byte comparisons confirmed the one-import delta and preserved boundaries. No network, module resolution, typecheck, build, Vitest, browser or native tests were performed by this child.

Current-head CI must verify the Item public parser, Candle parser, Item panel and production bundle contract. Prior measured `5be` browser/test evidence remains scoped to that prior source. This source receipt makes no current browser, native or production claim.
