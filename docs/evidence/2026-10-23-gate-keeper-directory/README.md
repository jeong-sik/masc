# Gate Keeper directory contract repair

Related issue: #45615. Code PR: #45663.

## Source and failure

- Reviewed code head: `0f73b0b1086cbab9190d6d4f8222579d04d11740`.
- Review base and observed server binary commit: `107c58401723313611f7c599bbe15225de5910da`.
- The current detailed Keeper producer emits nullable `last_failure` and `runtime_lane_observation`. Administrator responses also add `board_address` to readable and directory-error rows. The consumer's strict schema omitted those fields, so the complete directory was rejected.
- The displayed `status: expected error`/`meta: expected null` messages came from alternate error-row branches of the rejected union. They did not mean that every healthy row should become an error row.

The repair adds the eight producer failure causes and finite nullable timestamp, reuses the existing runtime lane observation schema, and validates optional administrator Board data through the existing exact-key/canonical-identity reader. Board absence remains legitimate on shared discovery. Strict excess-property rejection and name/count/duplicate checks remain. No server code, auth policy, runtime state, or connector configuration changed.

## Controlled live response comparison

The same authenticated live response was decoded by the before and candidate implementations. It contained 37 rows: 33 observed lane receipts, four producer-declared unreadable receipts, ten recorded provider failures, and 37 ready Board observations.

| Decoder | Result | Readable Keepers | Directory issues |
| --- | --- | ---: | ---: |
| Before | Schema failure | Not available | Not available |
| Candidate | Success | 37 | 0 |

Listing remained `total=37`, `limit=200`, `truncated=false`. `controlled-readback.json` stores the comparison without Keeper names or source error messages. The private raw response is not committed. The temporary comparison test and baseline decoder were removed before the final code commit.

## Focused validation

At the reviewed code head:

- Six committed frontend suites: **129 passed**, 29.00 s.
- Separate temporary same-response comparison: PASS. The earlier seven-suite run was 130 tests including that temporary test; it is not the committed suite count.
- TypeScript `tsc --noEmit` and changed-file ESLint: PASS.
- Dashboard production build: PASS, 30.10 s. `.build-identity.json` identifies the exact code head, with build stamp `2026-10-23T13:08:38.577Z`.
- Numbered changelog validation and `git diff --check`: PASS.
- Independent source and review-response agents inspected the exact head/base and found no unresolved P0-P2 issues. These internal source verdicts are separate from formal GitHub approval.

The retained tests cover all three directory row variants, valid observation absence, all lane observation states, current failure evidence, and malformed observations. Existing excess-property, count/identity, directory issue, connector matrix, and connector page behavior checks remain. `validation.log` records the selected results. No OCaml files changed and no local Dune, full repository regression, or CI watch was run. Existing large-chunk and font-resolution build warnings do not prove deployed asset readiness or a performance gain.

```sh
pnpm --dir dashboard exec vitest run \
  src/api/schemas/gate-keepers.test.ts src/api/gate-keepers.test.ts \
  src/components/keeper-runtime-walk-observation.test.ts \
  src/lib/board-address.test.ts \
  src/components/connector-keeper-matrix.test.ts \
  src/components/connector-status.test.ts --no-file-parallelism --maxWorkers=1
pnpm --dir dashboard typecheck
pnpm --dir dashboard exec eslint src/api/schemas/gate-keepers.ts \
  src/api/schemas/gate-keepers.test.ts src/api/gate-keepers.test.ts \
  src/lib/keeper-runtime-walk.ts
pnpm --dir dashboard build
```

## Browser result and boundary

One Ego TaskSpace (78) compared installed Dashboard port 8935 with the candidate Vite frontend on port 5188, proxied to the same real server. Both used the application's normal verified Dashboard authentication. No token was printed or committed.

For `#connectors?section=connector-status&connector=slack`:

- Installed UI: Keeper directory schema error, no usable roster. It also showed an existing installed Dashboard/server source mismatch.
- Candidate UI: directory-error indicator absent; Keeper filter present; **37 Keeper row controls** present in the DOM. `browser-observation.json` records the completed DOM evaluation. Before/after screenshots were captured and visually inspected; `browser-captures.json` records their hashes. Screenshots remain local because they contain live workspace data.
- Slack's existing disabled warning remains visible (`enabled=false`). This repair restores directory discovery; it does not activate Slack, repair transport, or establish a deployment.

The source stack is unmerged and the candidate bundle is uninstalled at this evidence point. The Dashboard artifact workflow must remain disabled per the user's earlier instruction. Browser task tabs and the temporary preview server are cleaned up after observation.
