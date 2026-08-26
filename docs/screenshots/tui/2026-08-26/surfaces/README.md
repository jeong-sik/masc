# Terminal UI surfaces — 2026-08-26

Captured from a live loopback runtime with `masc-tui` built at the commit below.

- Captured: `2026-08-26T05:22:30Z`
- Runtime: MASC `0.25.0` on port `8935`, server commit `5383718928`
- Terminal: `133 × 28`, Menlo 14, device scale factor `2`
- Reproduce: `python3 scripts/capture-tui-screenshots.py --out docs/screenshots/tui/2026-08-26/surfaces`

| # | Surface | Screenshot |
|---:|---|---|
| 1 | Overview | [PNG](01-overview.png) |
| 2 | Keepers | [PNG](02-keepers.png) |
| 3 | Lanes | [PNG](03-lanes.png) |
| 5 | Approvals | [PNG](05-approvals.png) |
| 6 | Acting | [PNG](06-acting.png) |

## What changed since the 2026-08-25 set

The agenda strip is the row above the composer — `14:45 진행 상황 체크 · kpr-06`
on the Overview frame. It names the next wake and whichever keeper is waiting
on a person, on every surface.

That strip is also why this set was captured twice. The first attempt drew no
footer at all: the strip took a row from the body, and the surfaces did not
know, so each drew one row too many and the frame cut the last one. Every
screen lost its key hints, version, base path and port the moment a wake
appeared. #30800 gave the number one owner; the footer above the strip in
these frames is that fix.

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

Two keeper names on the Lanes frame keep their own shape —
`rw-e0-r9-20260820~` and `k14`. They are canary run ids rather than the
`keeper-*` names the rule matches, and they name a run rather than a person.
