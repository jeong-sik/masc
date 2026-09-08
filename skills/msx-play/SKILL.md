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
- `masc_msx_save` and `masc_msx_restore` use named slots containing machine state and the input ledger. Saving replaces that slot: use your campaign prefix plus a fresh unique suffix for each retained checkpoint, within the tool's slot format, and verify the save receipt names the requested slot and intended state. Keep the last good checkpoint. A restore rewinds the shared machine, not just your view; confirm the driving handoff still holds before restoring.
- `masc_msx_change_disk` changes the floppy without rebooting and preserves modified media in checkpoints. Follow the game's disk prompt and confirm it with the key the game requests. Read the requested disk letter from the current image before choosing a catalog entry. An unchanged screen, missing prompt, or guessed transition is not a disk-change request. Preserve a fresh checkpoint before changing media; replacing it can invalidate open game files even though the CPU keeps running. If the requested letter is unreadable, retain that uncertainty and obtain a clearer observation instead of trying disks.
- `masc_msx_load` boots a new cartridge or disk and replaces the current machine/ledger. Calling it without `cart` still boots the BIOS: it is not a read-only inventory query. Read the inventory through the available inventory surface, or use already supplied media names. Do not load just to discover what is running.

Use the `observe-act-verify` Skill for unfamiliar screens: capture, identify the prompt, choose an action, then verify the resulting screen and values. A successful key call proves delivery, not that the requested action succeeded. All key edges are retained in the machine ledger with their frame and caller. After a transport timeout, observe before retrying; a changed screen alone cannot identify whose input caused it when another driver may be active. Consult the caller-tagged ledger when accessible, or retain that uncertainty and coordinate before further input.

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

Game save: `1`, `9`, Return, then `5`, Return opens the save flow. Swap to the user's data disk only when D is requested; follow the slot/name prompts. Swap back to B when requested. Emulator checkpoints and the game's own save/load are distinct behaviors to verify.

Keep local media filenames and the current campaign slot in session memory rather than treating one operator's inventory as universal. A long zero-human observer run ending in year 293 has been observed; it is not proof of a human unification victory. No full winning campaign is established by this Skill.

## Recover from a suspected bad transition

Save the abnormal state to a fresh slot before stepping again or restoring. Retain the last good slot, media identity, exact accepted inputs, frame numbers and images. Treat values displayed after corruption as untrusted; a later year or a BIOS logo does not prove a completed turn or a deliberate reboot.

A controlled Sangokushi II replay found that switching from B to A during an active campaign cleared the open file state while the game still needed `PACKDATA.DAT`, which was present on B. Replaying the same accepted inputs from the same earlier checkpoint while retaining B reached a readable diplomacy prompt; including the swap corrupted the screen. This establishes a failure of that media-change sequence, not a requirement to keep B inserted through legitimate save or load prompts. Follow the currently visible request for D or B when the game asks.
