# Dashboard Monitor IA Proof

## Header

- Date: `2026-05-20T20:52:36+09:00`
- Branch: `codex/dashboard-monitor-ia-20260520`
- Source analysis artifact: `/Users/dancer/me/memory/masc-oas-dashboard-monitor-ia-report-2026-05-20.html`
- Decision ID: `dashboard-monitor-ia-20260520`
- Scope: dashboard Monitor information architecture, route visibility, default monitor boards, and documentation contract.

## Required Improvements

| Requirement | Implementation evidence | Status |
|---|---|---|
| Monitor should open on Keeper Operations, not low-level runtime diagnostics. | `dashboard/src/config/navigation.ts` sets Monitor `defaultParams` to `{ section: 'agents' }`; `dashboard/src/components/status.ts` normalizes unknown Monitor sections to `agents`. | Done |
| Monitor primary sidebar should contain four operator lanes. | `dashboard/src/config/navigation.ts` exposes only `agents`, `fleet-health`, `runtime`, and `observatory` as visible Monitor sections. | Done |
| Diagnostics should remain routeable without dominating daily Monitor IA. | `cascade-config`, `doctor`, `transport-health`, `feature-health`, `journey`, and `cognition` remain configured with `hidden: true`; `runtime-panel` links diagnostics from Cascade & Runtime. | Done |
| Tool Monitor should be a compact operations board, not two large telemetry panels by default. | `dashboard/src/components/fleet-health-panel.ts` replaces the default dual panel with `ToolMonitorDefaultBoard`, using shared tool-quality data, summary tiles, failure categories, attention rows, and lane links. | Done |
| Evidence Timeline should separate timeline, activity graph, and live stream read paths. | `dashboard/src/components/observatory/observatory.ts`, `dashboard/src/refresh-scope.ts`, and `dashboard/src/tab-refresh.ts` gate `view=activity` and `view=live` refresh/read behavior separately. | Done |
| Keeper cognition should become a keeper detail/deep-link path, not a top-level primary Monitor sibling. | `dashboard/src/components/agent-roster.ts` adds selected keeper detail links to Cognition, Tool Access, and Runtime Trace while `cognition` is hidden in navigation. | Done |
| The IA contract should be durable outside the UI code. | `docs/DASHBOARD-INTEGRATION.md` adds `Monitor IA Contract` with default route, four primary lanes, hidden diagnostics, Tool Monitor behavior, and Evidence Timeline view contract. | Done |

## Verification

Commands were run from `/Users/dancer/me/workspace/yousleepwhen/masc-mcp/.worktrees/dashboard-monitor-ia-20260520`.

| Command | Result |
|---|---|
| `pnpm --dir dashboard typecheck` | Passed |
| `pnpm --dir dashboard exec vitest run --config vitest.config.ts src/config/navigation.test.ts src/refresh-scope.test.ts src/tab-refresh.test.ts src/components/status.test.ts src/components/status-tray.ts src/components/transport-beacon.ts src/components/agents-unified.test.ts src/components/agent-roster.test.ts src/components/fleet-health-panel.test.ts src/components/observatory/observatory.test.ts src/components/runtime-panel.test.ts src/components/cognition-plane.test.ts src/components/widget-solo.test.ts --no-file-parallelism --maxWorkers=1` | Passed: 11 test files, 138 tests |
| `pnpm --dir dashboard lint` | Passed with one pre-existing warning in `dashboard/src/components/common/virtual-list.ts:87` for an unused eslint-disable directive |
| `pnpm --dir dashboard build` | Passed with existing Vite chunk/import warnings |
| `git rebase origin/main` | Passed without conflicts before the final verification run |

## Residual Risk

- This proof verifies route contracts, refresh/read-path separation, and dashboard buildability. It does not include browser screenshot review because the change is primarily IA and data-routing logic.
- Local verification was repeated after rebasing onto `origin/main`.
