---
name: sangokushi-2
description: "Sangokushi II (Koei 1990, Japanese, 3-disk set) on the shared MSX: media set and verified origin slot, the province command menu, in-game save flow, media-change pitfalls, and one-call macros for the two verified key sequences. Apply a fact only when the visible prompt matches it."
---

# Sangokushi II

A turn-based strategy game played from three floppy images. Everything below
is an observation from a real campaign state, not a rule of the game: apply it
only when the visible prompt matches, and re-verify from the actual screen.

## Media

A = `sangokushi-2.dsk`, B = `sangokushi-2-b.dsk`, user data disk =
`sangokushi-2-data.dsk`. Catalog names only; no host paths. Verified origin
slot `sangokushi2-cao-pi-ready`: scenario 6, beginner, historical, 1 human
player as Cao Pi, province 10 awaiting its first command, frame 26865. It is a
test origin — after restoring it, save under your own slot prefix instead of
keeping the original.

## Province command prompt `(0-19)?`

Return with an empty entry reveals the command list; Space and F1 did not. A
numeric entry followed by Return selects that command instead.

| Number | Visible command | Meaning |
| --- | --- | --- |
| 0 | 待機 | Wait / finish province commands |
| 1 | 移動 | Move |
| 2 | 輸送 | Transport |
| 3 | 戦争 | War |
| 4 | 軍事 | Military |
| 5 | 人事 | Personnel |
| 6 | 外交 | Diplomacy |
| 7 | 計略 | Plots |
| 8 | 情報 | Information |
| 9 | 開発 | Development |
| 10 | 治水 | Flood control |
| 11 | 褒美 | Rewards |
| 12 | 施し | Relief |
| 13 | 商人 | Merchant |
| 14 | 徴収 | Levy |
| 15 | 地図 | Map |
| 16 | 委任 | Delegate |
| 17 | 放浪 | Wander |
| 18 | 特別 | Special |
| 19 | 機能 | Functions |

Observed transitions: `1`, Return asks for a destination numbered 1-41; `9`,
Return asks which officer should develop the province. Neither alone proves
movement or improved land. `0`, Return, `y`, Return advanced the observed
campaign from province 10 to 18.

Development is a sequence of decisions: `9`, Return; read the officer list
and select an officer; capture the resulting amount prompt before entering a
cost. One observed province 13 action (officer 5, cost 50) changed gold from
500 to 450 and a displayed province statistic from 20 to 27, returning to the
command prompt with the month unchanged. That demonstrates a completed action
in that state, not a fixed exchange rate or a universally best officer.
Compare the actual before/after resources, then preserve the result before
planning another action.

Functions submenu cancellation: in one observed province 11 state, the
functions submenu `(1-6)?` remained visible after `0`, Return and after Esc.
A subsequent Return by itself returned to the same province's main `(0-19)?`
prompt with resources and month unchanged. Verify that prompt before sending
province commands; do not assume Esc universally cancels.

## In-game save

`1`, `9`, Return, then `5`, Return (command 19 機能, option 5) opens the save
flow. Swap to the data disk only when the game requests D; follow the slot
and name prompts; swap back to B when requested. Emulator checkpoints and the
game's own save/load are distinct behaviors to verify separately.

## Media-change pitfall

A controlled replay found that switching from B to A during an active
campaign cleared the open file state while the game still needed
`PACKDATA.DAT`, which was present on B. Replaying the same accepted inputs
from the same earlier checkpoint while retaining B reached a readable
diplomacy prompt. That is a failure of one media-change sequence, not a rule
to keep B inserted at all times: follow the currently visible D or B request
when the game asks.

## Reading the screen

Bitmap modes (GRAPHIC6 openings and scenes) leave name-table residue:
`screen_text` there is not OCR of the visible scene. Read the actual image
artifact with `keeper_analyze_image` — the `msx-observe` Skill does the
capture and read in one call. A long unattended observer run ending in year
293 is not proof of a victory; no full winning campaign is established.

## Repeated sequences

- Ending the current province's commands (`0`, Return, `y` at the province
  `(0-19)?` prompt) is one call: the `sangokushi-2-end-command` composition
  Skill presses the verified sequence, waits for the settled screen and
  returns the observation. This is the verified province 10 to 18 transition.
- The save-flow entry is `1`, `9`, Return, `5`, Return at the province
  prompt: one `masc_msx_press` call with `sequence=true`. The disk prompts
  that follow are interactive: read the screen and swap media per the visible
  request; nothing pre-swaps disks.
