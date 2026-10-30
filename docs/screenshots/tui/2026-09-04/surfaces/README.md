# Terminal UI surfaces — 2026-09-04

Captured from the live loopback runtime with `masc-tui` connected to the running
server on port `8935`.

- Captured: `2026-09-04T06:47:00Z`
- Runtime: MASC `0.30.0` on port `8935`
- Terminal: `133 × 28`
- Reproduce: `python3 scripts/capture-tui-screenshots.py --out docs/screenshots/tui/2026-09-04/surfaces`

| # | Surface | Screenshot |
|---:|---|---|
| 1 | Overview | [PNG](01-overview.png) |
| 2 | Keepers | [PNG](02-keepers.png) |
| 3 | Lanes | [PNG](03-lanes.png) |
| 5 | Approvals | [PNG](05-approvals.png) |
| 6 | Activity | [PNG](06-activity.png) |

Keeper names and the base path in these frames are stand-ins of the same width,
so the layout is exact while the identifiers are not real. Structural surfaces —
ids, states, and model names — are safe to publish; the Board is deliberately
absent because its rows are free-text post titles that no name-and-path rule can
promise carry nothing private.

The `Acting` surface from earlier sets is now `Activity`, the newest-first feed
of every Keeper's tool calls, turn boundaries, and settlements (its `06` frame
here). The rest of the ring is unchanged in name and order.
