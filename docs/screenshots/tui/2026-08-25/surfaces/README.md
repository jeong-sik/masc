# Terminal UI surfaces — 2026-08-25

Captured from a live loopback runtime with `masc-tui` built at the commit below.

- Captured: `2026-08-25T10:37:08Z`
- Runtime: MASC `0.24.0` on port `8935`, server commit `be865dae4a`
- Terminal: `133 × 28`, Menlo 14, device scale factor `2`
- Reproduce: `python3 scripts/capture-tui-screenshots.py --out docs/screenshots/tui/2026-08-25/surfaces`

| # | Surface | Screenshot |
|---:|---|---|
| 1 | Overview | [PNG](01-overview.png) |
| 2 | Keepers | [PNG](02-keepers.png) |
| 3 | Lanes | [PNG](03-lanes.png) |
| 5 | Approvals | [PNG](05-approvals.png) |
| 6 | Acting | [PNG](06-acting.png) |

## What was changed before capture

Keeper names became `kpr-NN`, and the footer's base path became
`/home/demo/project`. Both replacements keep the original character count,
because the terminal is a fixed-width grid and a shorter stand-in would move
every cell after it on that row. That is why the redacted path reads
`/home/demo/proje` — it was cut to the width the real path occupied.

Nothing else was altered. Task ids, turn counts, model names, and timings are
what the runtime reported.

## What is not here

The Board surface is missing on purpose. Its rows are post titles written by
whoever posted them, so no name-and-path rule can promise a title carries
nothing private. The surfaces above hold ids, states, and model names, which a
rule can cover.
