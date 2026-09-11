---
name: msx-play
description: Play the shared MSX machine through image observation, sequential key input, disk changes and persistent checkpoints; learn game menus from their visible results.
---

# MSX play

The workspace has one machine shared with the TUI and other Keepers. Agree on a handoff with the current driver before changing it. Calls are serialized, but no enforced driver lease protects a sequence across calls. If another caller intervenes, discard the remaining planned inputs, capture the current screen and coordinate who continues. Watching is not exclusive ownership. Preserve an existing campaign before taking it over; do not restart at each wake.

## Primitive tools

- `masc_msx_screen` observes without advancing time. Keeper calls return a PNG `artifact`, dimensions and frame number together. Pass the artifact to `keeper_analyze_image`. Bitmap `screen_text` is name-table data, not OCR; `halted` or a constant PC alone does not identify an input prompt. The sprite attribute table rides only with `sprites=true` — pass it when you really need sprite positions, not by habit.
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

## Per-game Skills

Game facts — menu tables, in-game save flows, media-change pitfalls, verified key sequences — live in a Skill named after the game, not here. Before playing a loaded game, open its row in the Skill list; `sangokushi-2` is the first. Where no row exists, learn from the actual screens and report what repeated, so the knowledge can be distilled into one. Keep local media filenames and the current campaign slot in session memory rather than treating one operator's inventory as universal.

## Recover from a suspected bad transition

Save the abnormal state to a fresh slot before stepping again or restoring. Retain the last good slot, media identity, exact accepted inputs, frame numbers and images. Treat values displayed after corruption as untrusted; a later year or a BIOS logo does not prove a completed turn or a deliberate reboot.
