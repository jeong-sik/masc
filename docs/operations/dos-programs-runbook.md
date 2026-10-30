# DOS programs

The operator runbook for the DOS machine in the workspace. The Lane and its
Tools are game-neutral: a game is an operator-owned file or directory in the
DOS inventory, not an OCaml variant or a special path in MASC.

## Inventory and identity

DOS program assets live in the DOS add-on's state volume, at
`/state/.masc/dos/programs/` inside the worker container (the worker runs with
`--base-path /state`). The directory is never filled by installation and MASC
does not download commercial games. To put a game there, follow "Provision or
transfer state" in [machine-addon-state.md](../guides/machine-addon-state.md).
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
the autosave and game-written files reached durable storage. A save under a
name that already holds a checkpoint replaces it and reports what it held in
`replaced`. The names `autosave` and `autosave-prev` belong to the lane and a
save to either is refused.

A worker that starts restores `autosave` before its first call, with nobody
holding the controller; whoever moves the machine first takes it. It does so
only when `checkpoints/autosave.current` is there: the running machine writes
that file after a successful autosave and removes it on a load, a restore of
another slot, an exit, a failed autosave, a fault and an eject. It never falls
back to `autosave-prev`. Without the file, or with no `autosave`, the worker
starts with nothing loaded. With an `autosave` that does not restore it also
starts empty, and its activity feed and every no-machine answer
(`restore_failed_at_start`) say why. `masc_dos_screen` and `masc_dos_load` with no program then say what the
two autosave slots hold, under `autosave` and `previous_autosave`. Resume with
`masc_dos_restore` and `slot` set to `autosave`, or to `autosave-prev` when the
autosave is gone.

A machine started by `masc_dos_load`, or by `masc_dos_restore` of a named
slot, copies the `autosave` file to `autosave-prev` with its first autosave,
and what `autosave-prev` held is gone. Such a start therefore asks for consent
exactly when both files exist, readable or not. Without consent the call is refused
before anything changes, and the refusal names what `autosave-prev` holds
(`would_discard`) and the autosave that would move in (`moves_to_previous`).
To keep the old campaign, restore `autosave-prev` first and save it under a
name. To discard it, repeat the call with `discard_previous_autosave` set to
`true`. With no file in `autosave-prev`, or with only `autosave-prev` left, the
start asks nothing. A restore of `autosave` or `autosave-prev` never asks: the
machine restored from `autosave` goes on writing `autosave` and leaves
`autosave-prev` as it is, as a machine that was never stopped does, and the
machine restored from `autosave-prev` already holds what its first autosave
replaces.

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
