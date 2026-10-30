---
name: dos-play
description: Play the shared DOS machine with other Keepers — controller handoff, reading VGA screens through PNG images, choosing explicit input execution, the limits of settling observations, and where a game's own saves live.
---

# DOS play

This attached Add-on provides a DOS machine shared with other Keepers. Time
advances through machine execution steps, including idle wait clocks, only
when someone calls a tool. Game facts — menus,
key sequences, pitfalls — live in a Skill named after the game
(`sangokushi-3` is the first). Where none exists, learn from the screens and
report what repeated.

## Who is at the machine

The observation's `controller` names who may move the machine. Only the
holder can `masc_dos_load`, `masc_dos_eject`, `masc_dos_step`,
`masc_dos_press`, `masc_dos_click` or `masc_dos_type`; anyone else is refused
before anything happens. Watching (`masc_dos_screen`, `masc_dos_peek`) needs
no controller. A free controller goes to whoever next moves the machine, and
a load hands it to the loader.

In a hotseat game several human players share the machine. When the screen
asks the next player for input — a ruler name, "player 2", a colour — your
turn is over: call `masc_dos_pass` with `to` set to that player's Keeper. The
board post it makes @mentions them, which wakes them. Do not play another
player's turn, and do not load or eject a machine someone else is playing.
`masc_dos_pass` without `to` frees the controller when you are done.

## Reading the screen

`screen_text` is only the 80x25 text page. A game in a VGA mode draws its
own letters (Korean or Japanese menus, prompts) as pixels, so read the PNG:
`masc_dos_screen` returns the PNG as an image block alongside its structured
observation. Read that image; if the current model cannot interpret images,
report the limitation rather than infer the prompt. `frame_ascii` shows where something is drawn, not
what it says, and `frame_nonblack` only tells that the picture changed.

## Pressing and waiting

By default `masc_dos_press` and `masc_dos_type` advance after each key until an
empty keyboard poll overlaps unchanged screen memory between samples.
`settled: true` reports that observation. A game can still be in a timed
transition or repaint; this is not proof that its final prompt is ready.
`waiting_for_key` also records an empty-ring observation, not guest acceptance.

For one input followed by an explicit run, pass `until_ready: false` with the
machine-step allowance `steps`. Only the first key or character enters the BIOS
ring; execution continues for `steps` unless the program exits. The response
reports `steps_run` (budget consumed), `instructions_run` (guest instructions),
`elapsed_cycles` (emulated clocks) and `keys_pressed`, and always
reports `settled: false`. That false value does not itself mean the game is busy.
Read `masc_dos_screen` for the PNG before choosing another input. If the visible
transition still needs time, use `masc_dos_step` with `until_ready: false` without
repeating the key.

The default remains `until_ready: true`. Its batch continuation uses the same
limited settling observation, so do not chain keys across an unobserved screen
change. `keys_pressed` is the delivered prefix length; the remaining suffix
never entered the ring or ledger. Resume only the suffix you still intend to
send after reading the screen. A delivered key may be ignored or consumed by a
skip check rather than the intended menu.

## Saves

When the game writes a file (its own save), the lane keeps it under
`<worker-base-path>/.masc/dos/saves/<program>/` and mounts it at the next load, so an in-game
save survives an eject or worker replacement with the same persistent state volume. Save through the game's own menu
before a long pause. A save that did not reach disk is listed in `unsaved`
on the call that wrote it; the call itself still happened.

`masc_dos_save` keeps the whole machine under a slot name — CPU, memory,
screen, open files and the key ledger — without moving it, and anyone may
call it. It works in every game and keeps the exact moment, so save at the
end of your turn and before a risky choice. A save under a name that already
holds a checkpoint replaces it and says what it held in `replaced`; the names
`autosave` and `autosave-prev` belong to the lane and are refused.
`masc_dos_restore` with no slot
lists the saved ones; with a slot it puts that machine back and you hold the
controller, so restore only a game nobody else is playing. Restoring does not
touch the game's own save files.

## Loading

`masc_dos_load` with no `program` lists the inventory. A game directory with
several programs needs `boot` (for example `KOEI.COM`). Loading replaces the
machine: never load over a game someone else is playing.

## Autosave

After a `masc_dos_load`, `masc_dos_step`, `masc_dos_press`, `masc_dos_click`
or `masc_dos_type` that ends with an answer, the machine is written to the
fixed slot `autosave`, no call needed. Nothing is written when a call is
refused (no machine, another holder, a bad argument), when the program hit a
fault (that machine faults again on the next step), or when the program has
exited. In those cases the previous autosave stays. If the write itself fails,
the result still carries what you asked for, plus
`autosave: {"saved": false, "reason": ...}`.

After a restart the DOS worker restores `autosave` by itself before the first
call: the game is where its last autosave left it, nobody holds the
controller, and whoever moves the machine first takes it. It does this only
when the machine was still running when the worker stopped. After an eject, a
program exit, a fault or a failed autosave it starts with no machine. Only
`autosave` is restored, never `autosave-prev`.

With no machine loaded (after an eject, or after a restart with no
`autosave`, or with one that would not restore), a call that needs a machine
(`masc_dos_screen`, `masc_dos_peek`) and `masc_dos_load` with no `program` say
what the two autosave slots hold: `autosave` and `previous_autosave` in the
result, each with the program, steps, who saved it, when, and a `resume`
command. A file that is there but cannot be read shows as `unreadable` with the
reason. Read the fields and call `masc_dos_restore` yourself when you want a
slot back.

There are two lane-owned slots. `autosave` is the machine's latest state.
`autosave-prev` holds the autosave that was current when the running machine
started. A machine started by `masc_dos_load`, or by `masc_dos_restore` of a
named slot, copies the `autosave` file to `autosave-prev` with its first
autosave, and whatever `autosave-prev` held is gone. So such a start asks for
consent exactly when both files exist, readable or not:

- `autosave-prev` has no file: nothing is discarded. The autosave moves to
  `autosave-prev` and stays there. The start asks nothing.
- `autosave` and `autosave-prev` both exist: `masc_dos_load` with a program
  name, and `masc_dos_restore` of a named slot, are refused. The refusal names
  what `autosave-prev` holds under `would_discard` (program, steps, who saved
  it, when) and the autosave that would move in under `moves_to_previous`.
  Nothing is loaded and both files are as they were.
- To keep what `autosave-prev` holds, restore it first with
  `masc_dos_restore slot=autosave-prev`, which asks for nothing, and save it
  under a name with `masc_dos_save`. To go on and discard it, call the same
  tool again with `discard_previous_autosave: true`.
- Only `autosave-prev` is left: a start leaves it in place and asks nothing.

`masc_dos_restore slot=autosave` and `slot=autosave-prev` ask for nothing.
The machine restored from `autosave` goes on writing `autosave` and leaves
`autosave-prev` as it is, as a machine that was never stopped does. The
machine restored from `autosave-prev` already holds what its first autosave
replaces.
