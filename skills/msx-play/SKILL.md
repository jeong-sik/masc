---
name: msx-play
description: Play the shared MSX machine through image observation, sequential key input, disk changes and persistent checkpoints; learn game menus from their visible results.
---

# MSX play

The workspace has one machine shared with the TUI and other Keepers. Agree on a handoff with the current driver before changing it. Calls are serialized, but no enforced driver lease protects a sequence across calls. If another caller intervenes, discard the remaining planned inputs, capture the current screen and coordinate who continues. Watching is not exclusive ownership. Preserve an existing campaign before taking it over; do not restart at each wake.

## Primitive tools

- `masc_msx_screen` observes without advancing time. Keeper calls return a PNG `artifact`, dimensions and frame number together. Pass the artifact to `keeper_analyze_image`. Bitmap `screen_text` is name-table data, not OCR; `halted` or a constant PC alone does not identify an input prompt.
- `masc_msx_press` holds all `keys` together for `hold_frames` — a chord, like a direction plus fire — then releases them for the rest of `frames`. Set `sequence=true` to instead tap the keys one after another, each in its own frame window, so a menu path or a multi-digit command is one call; end a command entry with Return. Use short holds for a single press and observe at decision boundaries.
- `masc_msx_step` advances time without held keys. Use it for an observed transition or animation. Respect the current schema's per-call frame limit; do not repeatedly step an unchanged menu.
- `masc_msx_step_until_change` advances until the screen settles (two near-equal coarse views in a row; a blinking cursor alone is not movement) or the frame budget runs out. One call replaces repeated step+screen while a title, fade or level intro plays out. `changed=false` with `stable=true` means the screen did not move — the scene likely waits for a key, so read it and press; `stable=false` means the budget ran out mid-animation and another call continues it.
- `masc_msx_save` and `masc_msx_restore` use named slots containing machine state and the input ledger. Saving replaces that slot: use your campaign prefix plus a fresh unique suffix for each retained checkpoint, within the tool's slot format, and verify the save receipt names the requested slot and intended state. Keep the last good checkpoint. A restore rewinds the shared machine, not just your view; confirm the driving handoff still holds before restoring.
- `masc_msx_change_disk` changes the floppy without rebooting and preserves modified media in checkpoints. Follow the game's disk prompt and confirm it with the key the game requests. Read the requested disk letter from the current image before choosing a catalog entry. An unchanged screen, missing prompt, or guessed transition is not a disk-change request. Preserve a fresh checkpoint before changing media; replacing it can invalidate open game files even though the CPU keeps running. If the requested letter is unreadable, retain that uncertainty and obtain a clearer observation instead of trying disks.
- `masc_msx_load` boots a new cartridge or disk and replaces the current machine/ledger. Calling it without `cart` still boots the BIOS: it is not a read-only inventory query. Read the inventory through the available inventory surface, or use already supplied media names. Do not load just to discover what is running.

- `masc_msx_peek` reads bytes at a logical address (`address` as hex like "e000", `length` up to 256) and returns hex pairs; it also takes the 64K snapshot that the diff below compares against. Read-only by design: there is no write tool, and writing memory is the cheat the lane refuses.
- `masc_msx_ram_diff` reports what changed since the last peek: consecutive differing bytes as runs with address, length and before/after hex, capped at 64 runs (`truncated` says more existed). The snapshot survives a machine swap, so a reload after a peek reads as wholesale change — which it is.

Use the `observe-act-verify` Skill for unfamiliar screens: capture, identify the prompt, choose an action, then verify the resulting screen and values. A successful key call proves delivery, not that the requested action succeeded. All key edges are retained in the machine ledger with their frame and caller. After a transport timeout, observe before retrying; a changed screen alone cannot identify whose input caused it when another driver may be active. Consult the caller-tagged ledger when accessible, or retain that uncertainty and coordinate before further input.

## Finding state in memory

The screen is the expensive way to ask what changed; memory answers in bytes. To locate where a game keeps a value:

1. `masc_msx_peek` any address to take the snapshot.
2. Make exactly one meaningful input — one menu choice, one command — with `sequence=true` where a path is involved.
3. `masc_msx_ram_diff`: the changed runs are candidates for that action's state.
4. Confirm meaning against the screen (artifact reading): the run whose before/after matches the visible change — a menu id, a cursor, gold — is that state's address.
5. Record confirmed addresses in keeper memory as the game's address table. A few peeked bytes then answer routine questions; image reads stay for evidence, unfamiliar screens and periodic confirmation.

Re-verify a saved address after a reload or restore: the layout is usually the same, but confirm with one diff before trusting the table. If a diff after a clearly one-step action shows wholesale change, someone else drove the machine — treat the snapshot as lost and take a fresh peek.

## Sangokushi II: observed starting procedure

These observations came from a one-human Cao Pi campaign, scenario 6, January 220. Apply them only when the current prompt matches; discover other scenarios from their actual screens.

At the province command prompt `(0–19)?`, Return with an empty entry reveals the command list. Space and F1 did not reveal it. A numeric entry followed by Return instead selects that command.

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

Observed transitions: `1`, Return asks for a destination numbered 1–41; `9`, Return asks which officer should develop the province. Neither alone proves movement or improved land. `0`, Return, `y`, Return advanced the initial campaign from province 10 to 18.

Development is a sequence of decisions: at the province command prompt enter `9`, Return; read the officer list and select an officer; capture the resulting amount prompt before entering a cost. A saved or reread officer-list image does not establish the amount prompt after selection. In one observed province 13 action, officer 5 followed by a cost of 50 changed gold from 500 to 450 and a displayed province statistic from 20 to 27, returning to the command prompt with the month unchanged. This demonstrates a completed development action in that state, not a fixed exchange rate or a universally best officer. Compare the actual before/after resources and the statistic affected by the command, then preserve the result before planning another action.

Functions-menu cancellation: in one observed province 11 state, the functions submenu `(1–6)?` remained visible after `0`, Return and after Esc. A subsequent Return by itself (5 held frames, 180 total) returned to the same province's main `(0–19)?` command prompt with resources and month unchanged. Verify that prompt before sending province commands; do not assume Esc universally cancels or that a submenu option labelled "Exit" returns to play. This was a submenu cancellation, not the end of the province or month. From the restored main prompt, `0`, Return followed by `y` advanced province 11 to 8 in the observed campaign, still in January 220.

Game save: `1`, `9`, Return, then `5`, Return opens the save flow. Swap to the user's data disk only when D is requested; follow the slot/name prompts. Swap back to B when requested. Emulator checkpoints and the game's own save/load are distinct behaviors to verify.

Keep local media filenames and the current campaign slot in session memory rather than treating one operator's inventory as universal. A long zero-human observer run ending in year 293 has been observed; it is not proof of a human unification victory. No full winning campaign is established by this Skill.

## Recover from a suspected bad transition

Save the abnormal state to a fresh slot before stepping again or restoring. Retain the last good slot, media identity, exact accepted inputs, frame numbers and images. Treat values displayed after corruption as untrusted; a later year or a BIOS logo does not prove a completed turn or a deliberate reboot.

A controlled Sangokushi II replay found that switching from B to A during an active campaign cleared the open file state while the game still needed `PACKDATA.DAT`, which was present on B. Replaying the same accepted inputs from the same earlier checkpoint while retaining B reached a readable diplomacy prompt; including the swap corrupted the screen. This establishes a failure of that media-change sequence, not a requirement to keep B inserted through legitimate save or load prompts. Follow the currently visible request for D or B when the game asks.
