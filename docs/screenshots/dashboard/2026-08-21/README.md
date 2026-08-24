# Dashboard screenshots — 2026-08-21

These screenshots were captured from the live loopback dashboard at
`http://127.0.0.1:8935/dashboard/`.

- Captured: `2026-08-21T10:14:30Z`
- Runtime: MASC `0.23.0`, commit `ddb2c03e7f42589ddca5b5136df451922bf8a297`
- Documentation source: `origin/main` at `4abc3da1f3449ce05e910deadba188ab5ab638af`
- Viewport: `1440 × 1000`, device scale factor `1`
- Runtime state: `overall_status=degraded`, `operator_action_required=true`
- Scope: 13 primary rail screens, 7 visible Monitor/Work sections, and 4 Lab sections

The capture walked the primary navigation buttons and visible section links,
then verified the resulting hash route and rendered main content before saving
each image. Live messages, local paths, channel IDs, repository identifiers,
and Keeper names were replaced with documentation-safe placeholders in the
browser immediately before capture. No write action was performed.

## Primary navigation

| # | Screen | Route | Screenshot |
|---:|---|---|---|
| 1 | Overview | `#overview` | [PNG](01-overview.png) |
| 2 | Keepers | `#keepers` | [PNG](02-keepers.png) |
| 3 | Registry | `#registry` | [PNG](03-registry.png) |
| 4 | Monitor / Keeper Fleet | `#monitoring?section=agents` | [PNG](04-monitor-keeper-fleet.png) |
| 5 | Work | `#workspace?section=work` | [PNG](05-work.png) |
| 6 | Gate | `#approvals` | [PNG](06-gate.png) |
| 7 | Schedule | `#schedule` | [PNG](07-schedule.png) |
| 8 | Board | `#board` | [PNG](08-board.png) |
| 9 | Fusion | `#fusion` | [PNG](09-fusion.png) |
| 10 | Logs | `#logs` | [PNG](10-logs.png) |
| 11 | IDE | `#code?section=ide-shell` | [PNG](11-ide.png) |
| 12 | Connectors | `#connectors?section=connector-status` | [PNG](12-connectors.png) |
| 13 | Settings | `#settings` | [PNG](13-settings.png) |

## Monitor and Work sections

| # | Screen | Route | Screenshot |
|---:|---|---|---|
| 14 | Internal Agents | `#monitoring?section=internal-agents` | [PNG](14-monitor-internal-agents.png) |
| 15 | Tool Monitor | `#monitoring?section=fleet-health` | [PNG](15-monitor-tool-monitor.png) |
| 16 | Runtime | `#monitoring?section=runtime` | [PNG](16-monitor-runtime.png) |
| 17 | Observatory | `#monitoring?section=observatory` | [PNG](17-monitor-observatory.png) |
| 18 | Plans & Goals | `#workspace?section=planning` | [PNG](18-work-plans-goals.png) |
| 19 | Repositories | `#workspace?section=repositories` | [PNG](19-work-repositories.png) |
| 20 | Verification | `#workspace?section=verification` | [PNG](20-work-verification.png) |

## Lab sections

| # | Screen | Route | Screenshot |
|---:|---|---|---|
| 21 | Tools | `#lab?section=tools` | [PNG](21-lab-tools.png) |
| 22 | Safety Harness | `#lab?section=harness` | [PNG](22-lab-safety-harness.png) |
| 23 | Performance | `#lab?section=performance` | [PNG](23-lab-performance.png) |
| 24 | Keeper memory health | `#lab?section=keeper-memory-health` | [PNG](24-lab-keeper-memory-health.png) |
