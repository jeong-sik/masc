# Historical Dashboard Item workspace-authority candidate

This directory records the 2026-09-30 candidate, not the current PR head. Every entry in `source-sha256.json` matches its file at `beef16127fee6754b31c3da04bea8dc4750aed75`; that comparison was verified while reconciling the stack. Read the original README bytes through that commit when comparing its recorded README hash. The composition and syntax/typecheck receipts retain their original identities and limits.

Current production code and tests are integrated in parent `cc9c1556d96740f78b461ff9fa8bdd131731ba1e`. The remaining child changes include the workspace browser scenario in explicit artifact capture and the existing Item HTML fixture in preview inputs. This historical candidate receipt does not establish current native, browser, installed or release behavior.

Except for the explicitly refreshed frozen-source manifest, all candidate, parent, failure and unverified statements below describe the dated candidate work unless an explicit source is cited.

## Candidate provenance

- Local branch: `fix/dashboard-item-current-preview-20260930`.
- Historical publication parent supplied by the root agent: `a065328066d9996f8658238e3077cad70c2c063c`, on `feat/item-economy-integration-20260930`.
- Local partial baseline: `4e12031c141d30dafde4aa604ca05c22660e9395`. It starts from old local integration `09826ddd4f4f4e66432f40c2902493ea99c6f4b0`, imports the current parent's three overlapping consumers and two browser contract files, then composes the workspace repair. It is not a full checkout of the actual parent's tree. Publication must apply only the delta from this local baseline onto the actual full parent tree.
- `composition.json` records the supplied parent, local import commits and verified Git blob identities of all five imported files. Existing account-revision refresh, free-purchase/repricing tests and the controlled reactive demo revision updater are preserved. The existing browser script remains byte-identical to its imported current-parent version.
- This is a dependent Dashboard consumer fix. The base is an integration candidate, not a statement that the Item feature shipped on main.
- `source-sha256.json` records the source blobs frozen at commit
  `337f547de110f9fdfa3c4abe4609352d862d27ae`, including the browser workflow. Verify each entry with
  `git show 337f547de110f9fdfa3c4abe4609352d862d27ae:<path>` and SHA-256. Later stack recomposition does not
  change this receipt's source scope. The README and manifest themselves are
  excluded to avoid self-referential hashes. Historical composition and syntax
  receipts retain their original scope; no new runtime result is claimed.
- Changelog fragment `40190.md` cites the assigned child PR #40190; no placeholder was published.

## Reachable defect

`KeeperItemsPanel` previously admitted an account using Keeper name, portrait equipment, wallet and its local refresh revision. It did not subscribe to workspace authority. An accepted execution snapshot can move between different workspace roots while all those values and the project display name remain identical. The panel consequently retained the previous owned-item and catalog-price rows, and a previously started account read could publish after the change.

The execution producer already emits `status.workspace_root = config.base_path` from `workspace_status_json`, through both the ordinary and fallback execution payloads. The process publication epoch alone cannot identify a workspace change inside that process. `mergeServerStatus` may retain the last display root when the current raw status omits it, so that merged display value cannot authorize an account read.

## Boundary repair

The store exposes a read-only projection of the accepted response's current raw workspace root, process epoch and existing hydration request generation. A frozen object is retained for unchanged authority and replaced when that tuple changes. Returning A after B produces a different token from the original A. No extra request counter or wire field is introduced; publication generation is excluded from the tuple so ordinary publications do not trigger account rereads.

Malformed or missing current roots withdraw authority. Epoch invalidation and reconnect reset also withdraw it; the existing hydration admission rejects stale reconnect requests. Keeper Items subscribes to this authority, withdraws account/error rows when it changes, and makes a fresh read when it becomes available. Both fulfillment and failure check the captured token against the live store as well as the existing AbortSignal.

## Regression source

The existing happy-dom/Preact component suite exercises the real accepted store hydration path and mocks only the account transport and unrelated portrait/badge renderers. Its added cases specify:

1. Same-project A → B → A, with the exact same Keeper object, equipment and wallet; distinct owned sets and catalog prices; held first-A refresh released after returning to A; no rerun for unchanged-authority publication; fresh A read accepted.
2. Missing raw root despite a retained display root; null/numeric/empty/whitespace malformed roots; a held old failure delivered in the same transition before effect cleanup; reconnect withdrawal, stale request-generation refusal, and current Off response recovery.

The prior six cases retain their coverage with a real accepted workspace seeded before each mount: money precision, ready/off/disabled/error, Keeper switches, changed equipment and changed wallet. The refreshed parent's two additional free-purchase and repricing cases are also retained.

The isolated `dashboard/src/demo/keeper-items-fixture.ts` also seeds an explicitly labeled fixture execution response through this admission path. It does not have the real screen's HTTP/SSE bootstrap. This preserves the account read expected by the existing `dashboard/e2e/keeper-items.mjs` browser scenario; no missing-authority fallback was added to the production panel. Independent source review identified this caller after the initial local candidate, and the fixture repair is included in the final candidate.

## Prepared browser proof

The CI-only `vite.preview.config.ts` adds the existing Keeper Item HTML entry. The isolated demo exposes a workspace update function that hydrates explicit fixture roots with a test-only publication sequence while preserving its existing revision updater. The new `dashboard/e2e/keeper-items-workspace.mjs` scenario is separate from the parent's existing purchase/repricing browser proof.

The new scenario specifies A → B → A with fixed Keeper, wallet, outfit and project label; different owned sets/prices; held first-A response; withdrawn B rows while the fresh A response is held; current A acceptance; and withdrawal for missing current root. It prepares desktop/mobile screenshots and a `workspace-manifest.json` with input scopes, request receipts, transport failures and screenshot hashes. Real browser AbortSignal cancellation may prevent the held old response from reaching JavaScript; the manifest records that transport outcome and does not claim forced resolution of an aborted promise. The component regression separately specifies an abort-ignoring mock promise.

For a CI-produced preview, set `KEEPER_ITEMS_FIXTURE_URL` to its `/dev-fixtures/keeper-items-fixture.html`, set `KEEPER_ITEMS_ARTIFACT_DIR` and the exact `GITHUB_SHA`, then run `node dashboard/e2e/keeper-items-workspace.mjs` from an environment with the existing Playwright dependency. No preview was built or browser launched in this local work.

The existing `capture_item_browser` workflow step now invokes both Item browser
scripts. The workspace screenshots and `workspace-manifest.json` use the same
artifact directory and are included in its existing upload. This wiring is
source-verified; it is not a claim of a completed browser run on the new head.

## Evidence limits

`syntax-checks.json` retains Node `--experimental-strip-types --check` exit codes for four changed TypeScript source files and the preview config, Node `--check` for the new browser script, and `git diff --check`. These checks parse source and inspect whitespace only. Vitest, TypeScript typecheck, browser, Dune/native tests, CI, installation and production were not executed for this candidate. No runtime success, PR approval or release verdict is claimed.

Published as child PR #40190 over the full a065328066d9996f8658238e3077cad70c2c063c parent tree.

## Known CI failure and fixture repair

The root agent supplied the primary log excerpt from required PR run `36670626246`, job `109751275615`, at published head prefix `ce7d95ca11`: `src/components/keeper-items-panel.test.ts(81,24): error TS2532: Object is possibly 'undefined'.` The assertion that two mock calls occurred does not narrow an indexed array access for TypeScript's `noUncheckedIndexedAccess` rule.

The regression now obtains the held request's signal through optional call access and explicitly requires an `AbortSignal` before using it. A missing recorded call or signal fails the scenario; the A/B/A, abort and stale-response assertions stay intact. `typecheck-fixture-repair.json` retains the supplied failure excerpt, local source provenance and syntax/whitespace checks. These local checks do not prove the required typecheck or component suite now succeeds.

The separate Dashboard artifact run `36670622682` at the same published head prefix failed its existing production bundle contract on eager Effect modules. The source audit found inherited eager schema imports independently of the Item/store edge; attribution to the full a065 parent requires its baseline bundle run. This fixture repair changes neither bundle assertions nor those inherited imports. Targeted component/store execution and CI-built browser proof remain unverified.
