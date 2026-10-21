# Common Lane inventory application evidence

This is the bounded source and Dashboard check record for [PR #44801](https://github.com/jeong-sik/masc/pull/44801), worklist G01. It does not complete G01's broader connection graph, the 54-item worklist, A01's native artifact or A02's actual TUI lifecycle.

Source: `9c294b7d9d345a295c49c50995ccdd53de38d1cb`, base `ad6ca89213d57c9ac978e1f3e5704292c4334cf6`. The source blobs in `receipt.json` equal the blobs checked after rebasing onto that base; later changelog/worklist edits did not change them.

## Defect and changed boundary

The inventory panel inferred cleanup from worker count. An empty worker list cannot distinguish confirmed cleanup, pending cleanup, application failure and an unobserved application. The existing host application observation now travels with its original reconciled declaration. The server joins installation ID, source path, source bytes revision, desired revision and enabled setting against the fresh declaration. Missing, stale, duplicate or incomplete readings remain Unknown.

`Lane_addon_runtime.inventory` shares the existing Inspect application calculation. It reads retained state and an existing owner; it does not create a manager, reconcile configuration, start a worker or clean one up. Both strict TUI decoding and Dashboard decoding preserve the host state. Dashboard and TUI no longer infer it from `instances.length`.

## Checks actually completed

```sh
cd dashboard
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/api/lane-inventory.test.ts src/components/lane-inventory-panel.test.ts \
  src/components/lane-addon-connection.test.ts src/api/lane-declarations.test.ts \
  src/lib/lane-navigation.test.ts src/components/lane-navigation-flow.test.ts
pnpm exec tsc --noEmit
```

Six files / 62 tests pass; TypeScript exits 0. `dashboard-vitest.txt` retains the actual test output with trailing blank lines removed. `ocaml-parser.json` records ten changed ML/MLI files and parser-only results. `git diff --check` also passes.

The new host behavior tests cover unreconciled reads, the exact declaration identity join, conflicting/incomplete observations, no worker side effects and four different applications with the same empty worker inventory. The TUI test checks decoded state and refused contradictory protocol values rather than new screen wording/layout assertions. These OCaml test sources have not yet executed.

## Independent source review

`source-review.md` records an independent local source PASS for the bottom head and its captured base/full diff. It is not a formal GitHub APPROVE, an execution receipt or a verdict on later changes. MASC code/context review must inspect the final public identities.

## Remaining execution and UI evidence

Request one exact-source `addon-lifecycle` native proof and the three changed direct consumer suites (`test_lane_addon_reconcile,test_server_lane_inventory,test_tui_lane_inventory`) on the final published candidate. Dispatch acceptance is not a passing result. The native artifact must contain matching TUI/server/key-generator identities and completed behavior results. Actual On/Off/reconnect in an isolated workspace, original/new incarnations, cleanup status and original receipts need separate API and visible TUI evidence. No live operator runtime has been replaced.

The older native run [39555509454](https://github.com/jeong-sik/masc/actions/runs/39555509454) failed compiling `connection_worker_lines`; its 5 KB artifact contains only build diagnostics. The type annotation repair is present in this source through main, but that does not prove a rebuilt executable.


## Frozen execution requests

Native run [39592340135](https://github.com/jeong-sik/masc/actions/runs/39592340135) selects product source `5840bab469e8277194e405e6f2ec2cd712fc614e` and the fixed `addon-lifecycle` scenario. Minimal run [39592343953](https://github.com/jeong-sik/masc/actions/runs/39592343953) selects that same candidate and `test_lane_addon_reconcile,test_server_lane_inventory,test_tui_lane_inventory`. Both dispatches were accepted; results and artifacts remain unverified. The later evidence-only correction removes trailing blank lines from the retained log and records these request IDs. It changes no product/test source blob; future artifact evidence must name its actual `5840bab…` product source, not a later documentation head.
