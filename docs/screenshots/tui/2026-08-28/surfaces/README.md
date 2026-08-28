# Terminal UI surfaces — 2026-08-28

Captured from a live loopback runtime with `masc-tui` built at current repository state.

- Captured: `2026-08-28T01:44:51Z`
- Runtime: MASC `0.25.0` on port `8935`
- Terminal: `133 × 28`, Menlo 14, device scale factor `2`
- Reproduce: `python3 scripts/capture-tui-screenshots.py --out docs/screenshots/tui/2026-08-28/surfaces`

| # | Surface | Screenshot |
|---:|---|---|
| 1 | Overview | [PNG](01-overview.png) |
| 2 | Keepers | [PNG](02-keepers.png) |
| 3 | Lanes | [PNG](03-lanes.png) |
| 5 | Approvals | [PNG](05-approvals.png) |
| 6 | Acting | [PNG](06-acting.png) |

## What changed

Screenshots reflect the latest TUI rendering engine with differential frame presentation, terminal palette balance, and syntax lexers.

## What was changed before capture

Keeper names were redacted to length-preserving `kpr-NN` stand-ins, and the footer base path was redacted to preserve privacy on public documentation.
