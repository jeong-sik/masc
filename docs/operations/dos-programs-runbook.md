# DOS programs

The operator runbook for the DOS machine in the workspace. The Lane and its
Tools are game-neutral: a game is an operator-owned file or directory in the
DOS inventory, not an OCaml variant or a special path in MASC.

## Inventory and identity

DOS program assets live under `<base-path>/.masc/dos/programs/`. The directory
is never filled by installation and MASC does not download commercial games.
Use the read-only `masc_dos_inventory` Tool before loading a program. It lists
standalone files and directories, and for a directory lists each direct file
with its kind, byte length and SHA-256. It reads files only to calculate those
digests; it does not start a machine, take the controller, or interpret a
game's private format.

Use `masc_dos_meta` before a run when the emulator identity matters. It reports
the linked `ocaml-dos` source digest, the digest at the CI pin, and whether the
two match. A mismatch is a deployment/build problem to record with the run;
it is not a game failure.

## Loading a game directory

`masc_dos_load` accepts an inventory name, never a host path. A standalone
`.EXE` or `.COM` is loaded by its inventory name. A directory is loaded with
the executable named after the directory, or the only executable when there is
one. When several programs are present, pass the executable explicitly:

```json
{"program":"samguk3","boot":"KOEI.COM"}
```

The selected executable and every direct file beside it are mounted in the DOS
guest. DOS folds names case-insensitively; two inventory names that collide
after folding are refused. A missing companion file is an asset-set problem:
the inventory view shows what MASC can mount, while the game's own load result
shows what it actually reached.

Directory entries also report `executable_candidates` and `default_boot`.
When more than one candidate remains ambiguous, pass `boot` explicitly rather
than relying on a title-specific guess.

The first `masc_dos_load` result is an observation, not a compatibility
verdict. Read `masc_dos_screen` after a load. The result includes text and a
graphics frame, the loaded program, mounted file names, instruction count,
input state, and the linked core identity.

## Driving and preserving a run

`masc_dos_press`, `masc_dos_click`, and `masc_dos_type` deliver input through
the shared DOS Lane. `masc_dos_step` advances instructions without input. Each
call is bounded; continue from the returned observation instead of assuming a
single call represents a game turn. The controller belongs to one caller at a
time and is handed off with `masc_dos_pass`.

`masc_dos_save` writes a named whole-machine checkpoint and
`masc_dos_restore` lists or restores one. A checkpoint is emulator continuity,
separate from a game's own save menu. Keep a named checkpoint before a battle,
disk-like asset transition, or restart test. The Tool result reports whether
the autosave and game-written files reached durable storage.

## What counts as complete

A title screen or a long instruction run proves that the core can render and
advance that image. It does not prove a complete campaign. Record the core
identity and user-owned asset inventory, then verify the stages relevant to the
game: interactive menu, scenario start, at least one battle, game save, server
restart, checkpoint restore, and an observed ending. If an asset set is
incomplete, keep that run as a diagnostic result and obtain the missing
operator-owned files before calling the ending unverified.

The same contract applies to Romance of the Three Kingdoms 3 and to other DOS
games. Game-specific key layouts may live as data in the Play pad inventory;
the DOS Lane and its Tools do not branch on a title name.

## Current measurements

On 2026-10-08, the current pinned `ocaml-dos` core reported source digest
`57ee37daab1a4cd93e6fa9480918286a`, matching the MASC CI pin. A user-owned
Sangokushi III directory booted through `KOEI.COM`, reached a rendered battle
screen, and continued through `407,100,000` instructions with no guest fault or
process exit in the observed run. This establishes long-run Lane/Tool
continuity and battle rendering; it does not establish a campaign ending.

That inventory contained `END.EXE`, whose bytes reference `ENDSTIL`, but no
`ENDSTIL.DAT` file. The asset set is therefore incomplete for an ending probe;
the missing user-owned file must be supplied before that result can be called
an emulator or Lane failure.
