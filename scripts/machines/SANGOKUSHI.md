# Local Sangokushi play

Use the [local machine runner](README.md) with copies of your own game media.
Keep its process running and send **one decision at a time**. After each input,
request `screen` and inspect the returned PNG before choosing the next input:

```json
{"operation":"screen","arguments":{}}
```

A delivered key is not an accepted game action. Read the prompt, ruler, city or
province, and resource values; record the result before proceeding. Use `step`
for a visible animation or loading transition, not to wait out an unchanged
menu. Bitmap `screen_text` is not a transcription of the picture.

The local observations below used workers built from MASC
`2d296d4b6758647b9dce84ca6887722c7f3b1fa3` by
[run 37836011821](https://github.com/jeong-sik/masc/actions/runs/37836011821).
The game sessions were run separately from CI. That worker does **not** include
`export_disk`; the new tool's actual game-save export/reload is still awaiting
execution. Check the runner's discovered `tools.json` before using it.

## Sangokushi II on MSX

Provide the C-BIOS triple and the game's A, B and data-disk images in the
inventories described by the runner guide. Names below are examples; substitute
your catalog names. Start with A:

```json
{"operation":"load","arguments":{"cart":"sangokushi-2.dsk"}}
```

At the new-game menu, choose `1`, Return; select the scenario, Return. When the
screen explicitly requests B, swap to B and then press Return:

```json
{"operation":"change_disk","arguments":{"disk":"sangokushi-2-b.dsk"}}
{"operation":"press","arguments":{"keys":["return"],"hold_frames":5,"frames":30}}
```

Inspect a screen between those calls to verify the swap response, and again
after Return. Answer each player, ruler, level and mode prompt separately.
Select at least one human player for interactive play. Scenario 6 with Cao Pi
reached the January 220 province-10 command prompt in the local run.

At the province `(0-19)?` prompt, an empty Return shows the command list.
Numeric commands take Return. For example, development begins with:

```json
{"operation":"press","arguments":{"keys":["9","return"],"sequence":true,"hold_frames":5,"frames":30}}
```

Read the officer list before selecting an officer, then read the amount prompt
before entering a cost. The observed Sima Yi action spent 50 gold (1000 → 950)
and changed land 65 → 72. These are results of that campaign, not a fixed yield.
`0`, Return ends province commands after the game's confirmation; another
province can follow in the same month.

For war, command `3`, Return asks for the target province. Select officers one
at a time and confirm each with Return; an empty Return finishes the selected
roster. Read the gold, food and confirmation prompts before answering them.

### Place units on permitted hexes

At `<武将>を配置して下さい(0:配置)`, digit keys move the cursor and `0` places
the officer. The next officer can start on the occupied hex. A disallowed tile
keeps the placement prompt; it does not by itself establish an emulator fault.

In one province-18 → 27 battle, starting at frame 16125, this sequence placed
Zhang Liao and Xiahou Dun. It is an example for **that terrain and starting
cursor**, not a universal deployment macro. Inspect the screen after every row:

| Visible decision | `keys` | `hold_frames` | `frames` |
| --- | --- | --- | --- |
| Place Zhang Liao at the starting cursor | `["0"]` | 5 | 30 |
| Move Xiahou Dun's cursor down-left | `["1"]` | 5 | 10 |
| Move it up to the permitted tile | `["8"]` | 5 | 10 |
| Place Xiahou Dun | `["0"]` | 5 | 30 |

For example, the second row is:

```json
{"operation":"press","arguments":{"keys":["1"],"hold_frames":5,"frames":10}}
```

Read the next officer prompt or subsequent challenge/battle scene to confirm
placement. Battle menu digits act without Return; appending Return can cancel the submenu just
opened. Inspect movement or attack prompts before choosing a direction.

The observed duel challenge accepted `n`; after the transition, `1` opened
movement, another `1` selected normal movement, and `2` moved down before the
next officer's turn. Retreat `6` asked for a destination; the commander also
asked for `y` confirmation. Enter the displayed province number and Return.
In this run, Xiahou Dun was captured during retreat; the subsequent defeat
returned to Cao Pi's province-6 command prompt. Retreat is a game action with
consequences, not a guaranteed way to preserve both officers.

### Save the campaign

At the province prompt, command `19`, Return, then option `5`, Return opens the
game's save flow. Swap to the data disk **only when D is requested**. Follow the
slot and name prompts, inspect the displayed name, and wait for the game's
completed-write/return-to-B prompt before exporting or swapping back. Short
frame windows can miss typed characters; inspect the actual name rather than
assuming every character arrived. Follow the visible B request afterward;
swapping to A during an active campaign can disrupt the game's open files.

The local run wrote the data disk and preserved those changes in a checkpoint;
the original disk file remained unchanged. The proposed `export_disk` workflow
is described below and has not yet been verified with that save.

## Sangokushi III on DOS

Launch the runner with `--machine dos`. Inspect the inventory and boot
`KOEI.COM` from your game directory; it runs the opening and main game:

```json
{"operation":"inventory","arguments":{}}
{"operation":"load","arguments":{"program":"samguk3","boot":"KOEI.COM"}}
```

At the opening, press Enter, then observe until the code box is visible. Only
for the observed `[孫李呂]` question, type `10183` and then Enter. Do not send the
code into a black transition screen or reuse it for different characters:

```json
{"operation":"type","arguments":{"text":"10183"}}
{"operation":"press","arguments":{"keys":["enter"]}}
```

Check `keys_pressed` and the visible field before Enter; an incomplete type call
must not be treated as a completed code. At the keyboard/mouse choice, Space
selects keyboard input. The local run's initial numeric menus required **number
then Enter**, including the new-game and scenario choices. Read each resulting
prompt instead of relying on older digit-only recipes. Scenario 1, one human
player and Cao Cao reached January 189 at city 10, Chenliu.

At the ruler's `(0-9)?` prompt, `5`, Enter opens development. Select a task,
officer and cost from the current lists. The observed 100-gold action reduced
gold from 3000 to 2900; the later report said land development had not changed.
Spending money does not prove a successful improvement. `0`, Enter and the
visible `y` confirmation end commands; inspect the next city/month.

Battle placement uses direction digits and `0`, without Enter. In an observed
two-unit defense, a wall tile refused Pan Feng's placement and another move up
made placement valid. At the battle menu, digits also act without Enter.
Movement reduced mobility 4 → 2; attacking an empty neighboring hex explicitly
returned “no enemy.” Read such refusals as game responses. Delegation `8` asks
for confirmation and hands the battle to the game's AI; it cannot be canceled.
The observed delegated battle ended in defeat and returned to a human campaign
prompt. This is not evidence of a manual attack hit, victory or the ending.

For an in-game save, open Functions `9`, then interruption `1`, then save `2`,
following each visible menu's input behavior. Choose an empty or owned slot and
confirm its number with Enter. Reopen the list and verify the month, ruler and
city. The local run saved February 189 Cao Cao, restarted the worker, booted
`KOEI.COM` afresh and loaded that slot from title option `2`; the resumed command
screen matched the pre-save screen. Check any `unsaved` entries before claiming
files reached disk. In this game, Esc often does nothing; an empty Enter at the
save/load submenu returned to the command prompt.

## Three different ways to preserve progress

| Method | What it preserves | How to resume |
| --- | --- | --- |
| Game's own save command | Campaign data in guest files or the MSX data disk | Boot the game and use its load menu |
| Runner `save` / `restore` | Complete emulator state and input history, including a partly finished turn | Start the same worker type and restore your named checkpoint |
| MSX `export_disk` | Mounted floppy's current bytes in a new catalog `.dsk` | Fresh-boot the game, then insert that exported data disk when requested |

Keep a new checkpoint before a risky action or closing the runner:

```json
{"operation":"save","arguments":{"slot":"campaign-before-battle"}}
```

On a later session using the same isolated workspace:

```json
{"operation":"restore","arguments":{"slot":"campaign-before-battle"}}
{"operation":"screen","arguments":{}}
```

Fresh checkpoints made with the tested MSX worker resumed interaction after
worker replacement. One older format-1 checkpoint restored a picture but reset
to C-BIOS after stepping; its cause remains unverified. A restored screenshot
alone does not prove compatibility. Preserve the old checkpoint and verify
continued input before depending on a restored campaign.

With a worker that discovers `export_disk`, finish the MSX game's data-disk
write and export **while that data disk is still mounted**:

```json
{"operation":"export_disk","arguments":{"filename":"campaign-data-01.dsk"}}
```

Choose a new name; existing names are refused. Verify the filename, byte count
and SHA-256 receipt, then test the game's own load flow after a fresh boot.
A data disk need not be bootable. Exporting B after swapping away from D exports
B, not the saved campaign on D. The actual game export/reload remains unverified
on the newer worker; retaining a checkpoint is currently the demonstrated MSX
restart path. No complete winning campaign or intended ending is established
by these local observations.
