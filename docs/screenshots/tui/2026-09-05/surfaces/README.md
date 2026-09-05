# Terminal UI surfaces — 2026-09-05

Captured from the live loopback runtime with `masc-tui` connected to the running
server on port `8935`.

- Captured: `2026-09-05T15:41:49Z`
- Runtime: MASC `8a068e17a6` on port `8935`
- Terminal: `133 × 28`
- Reproduce: `python3 scripts/capture-tui-screenshots.py --out docs/screenshots/tui/2026-09-05/surfaces`

| # | Surface | Screenshot |
|---:|---|---|
| 1 | Overview | [PNG](01-overview.png) |
| 2 | Keepers | [PNG](02-keepers.png) |
| 3 | Lanes | [PNG](03-lanes.png) |
| 5 | Approvals | [PNG](05-approvals.png) |
| 6 | Activity | [PNG](06-activity.png) |

## What is a stand-in here

Everything below is replaced at the same width, so the layout is exact and the
identifiers are not real.

- **Keeper names** and the **base path**, as in earlier sets.
- **Task titles**, which are new in this set. The 2026-09-04 frames shipped real
  ones, complete with issue numbers, because the rule only covered names and
  paths. A title is a sentence somebody wrote — the same reason the Board is not
  captured at all — so the Overview's Tasks pane now draws from a fixed bank of
  invented ones.
- **Goal slugs** and **issue references**, for the same reason.
- **Any remaining CJK text.** Every label this TUI draws is English, so Korean
  left anywhere on screen came from a person: an agenda line, a wake reason, an
  approval body. It reads `redacted`.

Structural cells — ids, states, model names, timings, costs — are published as
they are. The Board is still absent: its rows are free text end to end, and
nothing short of not capturing it can promise what they hold.

## What the script now refuses

Redaction edits the DOM while the renderer owns it, so a frame arriving after
the edit redraws the row from the terminal buffer, where the real text still
lives. That race is not theoretical: it is why the first attempt at this set
published real Keeper names on the Keepers surface — whose rows tick every
second — while the quieter Overview came out clean.

The capture now stops the terminal's input for the length of one frame, and
then checks the drawn text for every name it was asked to hide. If one survived,
the run stops with `REFUSED` rather than writing a PNG. A leaked frame looks
exactly like a good one, so this is checked rather than assumed.
