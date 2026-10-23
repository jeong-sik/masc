# Dashboard residue cleanup and context observation evidence

Related issue: #45567. Native Stack #45588; source layers #45586, #45587, #45601.
This records source cleanup and a candidate Dashboard preview. It does not record a merge, installed bundle replacement, server restart, or transport repair.

## Fixed source identities

| Layer | Head | Review base |
| --- | --- | --- |
| Disconnected components/styles | `03c2206fdfa7ef142b937aff8ab905b1b7b1a753` | `b4bd81124965c7829df08a3d8e36dec5027865a3` |
| Context observation diagnostics | `0d414b2a2536133c4ab91b11769ce832e635c3c2` | `03c2206fdfa7ef142b937aff8ab905b1b7b1a753` |
| Canonical routing/visit metrics | `ab64e15c82e57d4428db1ddd18a14bd485af3331` | `0d414b2a2536133c4ab91b11769ce832e635c3c2` |

Independent source and review-response agents inspected these exact identities. Both found no unresolved P0-P2 issues. These internal source verdicts do not constitute a formal GitHub approval or installed-runtime validation.

## Cleanup boundary

- Removed eleven disconnected chat molecule adapters and five dedicated test files. Import/reachability inspection included dynamic imports and worker URLs. The production chat primitives, VirtualList, worker entry points, and adaptive FPS utility remain.
- Removed orphan telemetry/FSM/waterfall/demo styling. The retained virtual-list rules already exist identically in `keeper-v2/perf.css`, which remains imported by the application.
- Removed four retired route aliases in #45586, then the remaining eighteen aliases and their two redirect maps in #45601. One of those eighteen, `command:gate`, is also removed by the separate unmerged #45534; this stack does not include that PR's broader Gate UI/Memory Lens cleanup. Reconcile that one-line overlap when integrating the stacks.
- Removed the unused activity range conversion and redirect-only client/server telemetry field, parser, and metric label. Canonical navigation event counters remain. Server allowlists now match fifteen current surfaces and the current section lists, including Lane Inventory, Artifacts, and Account.
- Retained canonical section, connector-filter, workflow-target, cockpit-mode, and malformed-section fallback behavior. Deleted tests whose only subject was retired routing/components.

Counts below compare the pinned base to the final code head, before adding this evidence document. They are physical diff lines, not a performance measurement.

| Category | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| Production TypeScript | 177 | 1042 | -865 |
| Styles | 0 | 349 | -349 |
| OCaml code/interface | 19 | 61 | -42 |
| Tests | 202 | 1188 | -986 |
| Documentation, including observation interface prose | 19 | 3 | +16 |
| Total | 417 | 2643 | -2226 |

Production TypeScript + styles + OCaml: **1,256 fewer lines**. The observation projection implementation did not change; its `.mli` prose is counted under documentation.

## Context diagnostic cause and measured result

The producer emits nine closed context absence reasons. The Dashboard decoder previously recognized five, rejecting four valid `not_observed` variants. The candidate adds their exact discriminated shapes and scope/evidence validation. Missing scope is not attributed to a provider: old records without a scope field can produce the same typed observation.

Expected lack of occupancy evidence is informational. Read/parse failures and invalid payloads remain errors; over-window raw evidence remains a warning. A valid or invalid unavailability receipt takes precedence over stale measurement fields. No occupancy percentage is fabricated or clamped.

Offline decoding of **the same captured live `/api/v1/operator` response**:

| Decoder | Unique Keepers | Invalid context payloads | Valid usage-scope-unavailable |
| --- | ---: | ---: | ---: |
| Before | 37 | 7 | 0 |
| Candidate | 37 | 0 | 7 |

This is a controlled decoder comparison, not a claim that actual context occupancy became observable. The captured server identified itself as `68ec8fb2c52545c68600928524dcc12945e55ee7`. No runtime records were rewritten.

## Focused validation

At final code head `ab64e15c82e57d4428db1ddd18a14bd485af3331`:

- Sixteen selected frontend suites: **498 passed**, 38.36 s. Includes retained chat rendering, VirtualList, route/config/mode navigation, visit telemetry, both wire normalizers, context contract, Command, Fleet, and Keeper rail.
- TypeScript `tsc --noEmit`: PASS.
- ESLint on changed frontend files: PASS.
- Frontend production build: PASS, 26.74 s. Its `.build-identity.json` records the exact code head above and `.build-stamp` is `2026-10-23T10:57:14.416Z`.
- Fragment validator: 122 fragments OK before this evidence layer. `git diff --check`: PASS.
- OCaml parser-only checks of navigation-event implementation/interface/test: PASS. No local Dune build, OCaml typecheck/runtime test, full repository regression, or CI watch was performed.

Build warnings about existing unresolved font URLs and large chunks remain; successful bundling does not prove deployed asset availability or a speed improvement.

Reproduction commands (from the candidate checkout):

```sh
pnpm --dir dashboard exec vitest run \
  src/components/chat/primitives.test.ts \
  src/components/chat/primitives-v2.test.ts \
  src/components/chat/primitives-interleave.test.ts \
  src/components/chat/primitives.a11y.test.ts \
  src/components/common/virtual-list.test.ts \
  src/config/navigation.test.ts src/router.test.ts \
  src/context-observation-contract.test.ts \
  src/keeper-store-normalize.test.ts src/operator-normalizers.test.ts \
  src/components/ops/index.test.ts src/components/ops/cmd-skin.test.ts \
  src/components/keeper-workspace/keeper-workspace-rail.test.ts \
  src/components/agent-roster.test.ts src/lib/nav-telemetry.test.ts \
  src/cockpit-entrypoints.test.ts --no-file-parallelism --maxWorkers=1
pnpm --dir dashboard typecheck
pnpm --dir dashboard build
python3 scripts/changelog-fragments.py check
```

## Browser observation and limits

One Ego TaskSpace (55) compared the installed Dashboard to a Vite candidate proxied to the same real server. Screenshots were captured and visually inspected; their local filenames and hashes are in `browser-captures.json`. They contain live workspace data and remain local rather than being committed publicly.

- Installed Command rendered valid `usage_scope_unavailable` receipts as an invalid-payload warning.
- Candidate Command rendered a collapsed “context occupancy unobserved” note; expanding it showed each Keeper's actual reason. Final capture had nine unique Keepers and no context-invalid alert. The earlier offline capture's seven and the later browser's nine are different observation times, not a before/after population change.
- Canonical Monitor `fleet-health&view=tool-quality` rendered current metrics. Canonical Connectors `connector-status&connector=slack` selected Slack.
- Connector directory decoding exposed separate Gate Keeper schema drift, tracked in #45615. Slack was already disabled by its configuration. Neither issue was hidden or changed by this cleanup.
- A prior preview showed reconnect/error-console indications; the final context capture showed connected status with no console badge. This does not establish a transport repair. The installed Dashboard also showed a bundle/server identity mismatch after an external runtime change; this work does not replace that installed bundle.

Private logs are named `masc-cleanup-final-{tests,types,eslint,build}-20261023.log`; the controlled readback is `masc-context-live-readback-20261023.json`. Candidate browser tabs and its temporary Vite server were stopped after verification. The Dashboard artifact workflow remains subject to the user's explicit instruction to keep it disabled.
