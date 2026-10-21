# Common Lane inventory application evidence

This is the bounded source and Dashboard check record for [PR #44801](https://github.com/jeong-sik/masc/pull/44801), worklist G01. It does not complete G01's broader connection graph, the 54-item worklist, A01's native artifact or A02's actual TUI lifecycle.

Historical source: `9c294b7d9d345a295c49c50995ccdd53de38d1cb`, base `ad6ca89213d57c9ac978e1f3e5704292c4334cf6`. `receipt.json` and the original 62-test Dashboard log below describe that fixed source. They do not certify later rebases. In particular, main G03 added `host_requests` parsing and types to `dashboard/src/api/lane-addons.ts`: its recorded blob `26c20281022afaa57161127dd2c0e9fa14a171f4` differs from the restacked blob `137805790e52424fb1ec88dc7dcfb44f48828954`.

The later restack has its own bounded Dashboard record below. Original source review, failed compilation, repaired historical executions and actual UI observations remain separate evidence; none is promoted to execution of the restacked source.

## Defect and changed boundary

The inventory panel inferred cleanup from worker count. An empty worker list cannot distinguish confirmed cleanup, pending cleanup, application failure and an unobserved application. The existing host application observation now travels with its original reconciled declaration. The server joins installation ID, source path, source bytes revision, desired revision and enabled setting against the fresh declaration. Missing, stale, duplicate or incomplete readings remain Unknown.

`Lane_addon_runtime.inventory` shares the existing Inspect application calculation. It reads retained state and an existing owner; it does not create a manager, reconcile configuration, start a worker or clean one up. Both strict TUI decoding and Dashboard decoding preserve the host state. Dashboard and TUI no longer infer it from `instances.length`.

## Original checks at the historical source

```sh
cd dashboard
pnpm exec vitest run --config vitest.config.ts --no-file-parallelism --maxWorkers=1 \
  src/api/lane-inventory.test.ts src/components/lane-inventory-panel.test.ts \
  src/components/lane-addon-connection.test.ts src/api/lane-declarations.test.ts \
  src/lib/lane-navigation.test.ts src/components/lane-navigation-flow.test.ts
pnpm exec tsc --noEmit
```

Six files / 62 tests pass; TypeScript exits 0. `dashboard-vitest.txt` retains the actual test output with trailing blank lines removed. `ocaml-parser.json` records ten changed ML/MLI files and parser-only results. `git diff --check` also passes.

The new host behavior tests cover unreconciled reads, the exact declaration identity join, conflicting/incomplete observations, no worker side effects and four different applications with the same empty worker inventory. The TUI test checks decoded state and refused contradictory protocol values rather than new screen wording/layout assertions. These OCaml test sources had not executed in this original check record.

## Separate Dashboard checks after the G03 restack

`restack-dashboard-receipt.json` binds the existing follow-up checks to source `3b69416ac155b423806c7c81f2dc3d129be328ae`, base `ea2a60e467e6b2ac1761dba75b21da3e4fb582e2`, whose product layer is `326085874f6785c91bde9a41108a6ea5b02fd793`. The changed API blob is `137805790e52424fb1ec88dc7dcfb44f48828954`. These checks followed the actual G01/G03 API conflict resolution:

- `restack-dashboard-vitest.txt`: four files / 48 tests — inventory API, host-request parser, inventory panel and connection panel.
- `restack-dashboard-panel-vitest.txt`: one file / 44 tests — Add-on panel consumers.
- `restack-dashboard-tsc.txt`: empty compiler output; the separate receipt records `pnpm exec tsc --noEmit` exit 0. An empty file alone does not prove that result.

This is five distinct files / 92 tests, with the exact commands, selected test/API blobs and log hashes recorded separately. It is not a rerun of the original six-file / 62-test selection. Only trailing blank lines were removed from the retained Vitest logs; original and retained hashes are recorded separately. This documentation correction did not rerun the checks. No new OCaml, native artifact, installed binary or visible UI execution was performed for the restack. The later code record is not an approval of the current documentation head or completion of G01.

## Independent source review

`source-review.md` records an independent local source PASS for the bottom head and its captured base/full diff. It is not a formal GitHub APPROVE, an execution receipt or a verdict on later changes. MASC code/context review must inspect the final public identities.

## Execution and UI requirements recorded before the repair

Request one exact-source `addon-lifecycle` native proof and the three changed direct consumer suites (`test_lane_addon_reconcile,test_server_lane_inventory,test_tui_lane_inventory`) on the final published candidate. Dispatch acceptance is not a passing result. The native artifact must contain matching TUI/server/key-generator identities and completed behavior results. Actual On/Off/reconnect in an isolated workspace, original/new incarnations, cleanup status and original receipts need separate API and visible TUI evidence. No live operator runtime has been replaced.

The older native run [39555509454](https://github.com/jeong-sik/masc/actions/runs/39555509454) failed compiling `connection_worker_lines`; its 5 KB artifact contains only build diagnostics. The type annotation repair is present in this source through main, but that does not prove a rebuilt executable.


## Frozen execution requests

Native run [39592340135](https://github.com/jeong-sik/masc/actions/runs/39592340135) selects product source `5840bab469e8277194e405e6f2ec2cd712fc614e` and the fixed `addon-lifecycle` scenario. Minimal run [39592343953](https://github.com/jeong-sik/masc/actions/runs/39592343953) selects that same candidate and `test_lane_addon_reconcile,test_server_lane_inventory,test_tui_lane_inventory`. Both dispatches were accepted. The direct-consumer run later failed compilation, as recorded below; the native artifact remains unverified. The later evidence-only correction removes trailing blank lines from the retained log and records these request IDs. It changes no product/test source blob; future artifact evidence must name its actual `5840bab…` product source, not a later documentation head.


## Compiler execution feedback and repair

The original direct-consumer run39592343953 completed with failure while compiling `Lane_addon_runtime.attach_entry`: its `configuration` was inferred as `configuration_application option` rather than `configuration_owner option`. None of the selected behavior suites executed. The shared id/source_path labels introduced by the new observation record caused this source defect.

The historical repair source `c06acc2fa134286e61a6bdb570dc1aea3fdf3a3a` stores the original typed `configuration_owner` in `configuration_application.owner` rather than redeclaring its identity labels. Server and fixtures still compare ID, path, desired revision, source revision and enabled activity. `compiler-follow-up.json` records the failure, source repair and four parser-only results; repaired OCaml compilation and behavior were unverified in that record. The earlier `receipt.json`, Dashboard log, parser record and retained source review remain historical evidence for their explicitly named source, not a verdict on the repaired head. No Dashboard source changed in this repair.


The independent reviewer withdrew its earlier clean source verdict after inspecting that compiler failure. The retained `source-review.md` now binds the repaired bottom `c06acc2fa134286e61a6bdb570dc1aea3fdf3a3a`, base `ad6ca89213d57c9ac978e1f3e5704292c4334cf6` and complete diff `7d2d1b35e0ada751dfa86018021501d059e385de71e4ffb7db99e40711c39286`. No further P0–P2 was found in source; repaired compilation and behavior still required execution at that review. The original failed candidate is not called tested successfully.
