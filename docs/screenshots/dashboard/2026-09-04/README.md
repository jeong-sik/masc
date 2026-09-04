# Dashboard screenshots — 2026-09-04

These screenshots were captured from the live loopback dashboard at
`http://localhost:8935/dashboard/`.

- Captured: `2026-09-04T06:51:30Z`
- Runtime: MASC `0.30.0`, commit `bc2eec690de977d71b08a39aa799490bbf8b0b96`
- Documentation source: `bc2eec690de977d71b08a39aa799490bbf8b0b96`
- Viewport: `1440 × 1000`, device scale factor `1`
- Keeper names redacted: 18
- Reproduce: `python3 scripts/capture-dashboard-screenshots.py --out docs/screenshots/dashboard/2026-09-04`

The capture walked each hash route, verified the route it landed on, then
replaced Keeper names, absolute home paths, and long numeric channel ids with
documentation-safe placeholders before saving. Every frame carries a badge
saying so. No write action was performed.

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
