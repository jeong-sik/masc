# Dashboard disconnected UI and Gate consolidation

## Identity and scope

- Issue: #45521. Source PR: #45534. Evidence PR: #45546.
- Native Stack: #45547, source then evidence, targeting main through the top PR.
- Source: `9d72bccfac14725d2a1ef2a918b4e0db99f702d1`.
- Reviewed base: `9bf443caaeaf8c54db442c64cfb90d87d6b7cf26`.
- Remove MemoryLens and its exclusive memory primitives, AgentCapability,
  PersistenceStatus, and their five dedicated test files.
- Remove the eagerly imported memory visualization stylesheet and its scoped
  token bridge. Its 84 rules have only `mg-`, `gd-`, or `memory-v2` selectors;
  none has a current production component consumer. Actual Work dossier and
  task lineage use separate classes.
- Remove Command's duplicate approval pane and filter. The existing Gate
  surface remains the owner of approval decisions. Chat's approval link and
  the Intervene shortcut now navigate directly to `approvals`.
- Preserve actual memory health/context/ledger, interventions, keeper
  questions, server configuration and the independent Gate surface.
- Remove the obsolete Command Gate section alias and parity scenario; no
  compatibility route is added. Existing invalid-section defaults apply.

## Consumer and behavior evidence

Before removal, production imports of the three disconnected component
families were absent. Their only callers were their dedicated tests, plus
MemoryLens importing its exclusive primitives. This is code reachability
evidence, not a measurement of how often an operator uses other features.

The Gate surface retains its own initial and visibility refresh. Global
Gate signals continue to refresh in the application/event path. Removing its
inline Command copy does not remove the data producer or decision actions.

## Executed checks

```sh
cd dashboard
pnpm exec vitest run src/components/operations-panel.test.ts src/components/chat/primitives.test.ts src/components/ops/cmd-intervene-form.test.ts src/router.test.ts src/config/navigation.test.ts src/components/approvals/approvals-surface.test.ts --no-file-parallelism --maxWorkers=1
pnpm exec tsc --noEmit
pnpm exec eslint src/components/operations-panel.ts src/components/operations-panel.test.ts src/components/chat/primitives.ts src/components/chat/primitives.test.ts src/components/ops/cmd-intervene-form.ts src/components/ops/cmd-intervene-form.test.ts src/router.test.ts src/config/navigation.ts
pnpm exec vitest run src/components/ops/cmd-skin.test.ts src/components/ops/index.test.ts src/components/lab.test.ts src/components/dashboard-shell-tab-surface.test.ts --no-file-parallelism --maxWorkers=1
pnpm exec tsc --noEmit
pnpm exec eslint src/main.ts src/components/ops/cmd-skin.test.ts
pnpm run build
```

- Six affected navigation/interaction suites: **347 tests passed**.
- Four additional retained-surface suites after CSS removal: **24 tests passed**.
- TypeScript and changed-file ESLint: passed.
- Final source production frontend build: **passed in 12.32 seconds**.
  The generated build identity names `9d72bccfac14725d2a1ef2a918b4e0db99f702d1`.
- `git diff --check`: passed.
- No local Dune build, full regression run, or CI dispatch/watch.

The 347-test run preceded the CSS removal; the additional 24-test/type/lint
run covered that delta. The final source then removed two stale CSS comments
and was built. Removed-component and retired-view tests were deleted instead
of preserving assertions for absent features.

## Actual browser observations and limits

An isolated Vite frontend was inspected in ego-browser against the existing
local server. The installed before-page showed Command's Gate/HITL filter;
the candidate showed All, Intervene, Questions and Inspector without that
filter. Clicking the real Intervene Gate shortcut changed the URL to
`#approvals`. After lazy loading completed, the Gate surface displayed its
empty queue, mode controls and Always rules. The retained Lab memory page
also rendered actual workspace memory for 40 Keepers. No decision, mode change,
broadcast or keeper message was sent during observation.

Private screenshots and local execution logs were retained outside the
repository because the pages include live workspace data. The preview had
transient transport errors during server availability changes; the later Gate
observation showed a connected state and no Dashboard error. This is bounded
preview evidence, not a full runtime or error-free session certification.

## Independent source review

The source reviewer and response reviewer both read the final source and base
above and found no remaining P0-P2. Their P3 findings were stale comments in
the retained tests/token file; these were corrected and re-reviewed at the
final head. This internal source review is not a formal GitHub approval.

## Deployment boundary

This change is a source PR plus isolated frontend checks/build/preview.
It does not replace the installed Dashboard bundle or executable, restart the
server, or enable the disabled Dashboard artifact workflow.
