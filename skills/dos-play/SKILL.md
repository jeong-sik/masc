---
name: dos-play
description: Play the shared DOS machine with other Keepers — who holds the controller and how to pass it in a hotseat game, reading VGA screens through the PNG artifact, when a call has really settled, and where a game's own saves live.
---

# DOS play

The workspace has one DOS machine, shared by every Keeper. Time is 8086
instructions and moves only when someone calls a tool. Game facts — menus,
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
a Keeper's `masc_dos_screen` returns an `artifact`; pass it to
`keeper_analyze_image`. `frame_ascii` shows where something is drawn, not
what it says, and `frame_nonblack` only tells that the picture changed.

## Pressing and waiting

`masc_dos_press` puts each key into the BIOS ring and runs until the machine
is ready again. `settled: true` means the program asked for a key and the
screen stopped changing — your turn to read and decide. `settled: false`
with the budget spent means the program is still busy (an animation, an AI
turn): call `masc_dos_step` again rather than pressing more keys. A key call
proves delivery, not that the game accepted the choice: read the screen.
Menus often want the number and then `enter`.

Send one decision per call — a menu number and `enter` — and read the
picture before the next. Do not chain keys across a screen change: while a
game fades or loads it often shows a still screen and polls for a "skip"
key, which reads as settled, and the next key you queued is eaten by that
wait instead of reaching the next prompt. A sequence stops by itself at a key
that leaves the program busy; `keys_pressed` below the number you sent says
where, and the rest never reached the machine.

## Saves

When the game writes a file (its own save), the lane keeps it under
`<.masc>/dos/saves/<program>/` and mounts it at the next load, so an in-game
save survives an eject or a server restart. Save through the game's own menu
before a long pause. A save that did not reach disk is listed in `unsaved`
on the call that wrote it; the call itself still happened.

`masc_dos_save` keeps the whole machine under a slot name — CPU, memory,
screen, open files and the key ledger — without moving it, and anyone may
call it. It works in every game and keeps the exact moment, so save at the
end of your turn and before a risky choice. `masc_dos_restore` with no slot
lists the saved ones; with a slot it puts that machine back and you hold the
controller, so restore only a game nobody else is playing. Restoring does not
touch the game's own save files.

## Loading

`masc_dos_load` with no `program` lists the inventory. A game directory with
several programs needs `boot` (for example `KOEI.COM`). Loading replaces the
machine: never load over a game someone else is playing.

## Autosave

After every `masc_dos_load`, `masc_dos_step`, `masc_dos_press`,
`masc_dos_click`, `masc_dos_type` or `masc_dos_restore` that ran the guest —
settled or stopped at a fault — the machine is written to the fixed slot
`autosave`, no call needed. A call refused before anything ran (no machine,
another holder, a bad argument) writes nothing. The write never fails the
call: if it could not be written, the result still carries what you asked
for, plus `autosave: {"saved": false, "reason": ...}`.

After a restart, before anything is loaded, `masc_dos_screen` and
`masc_dos_load` with no `program` say whether an autosave exists — what it
is, when, and who saved it — under `autosave` in the result. Nothing resumes
it for you: read the field and call `masc_dos_restore slot=autosave`
yourself when you want it back.

There is one `autosave` slot, so the next call that runs the guest replaces
it. After a restart, call `masc_dos_screen` (or `masc_dos_load` with no
`program`) first. `masc_dos_load` with a program name starts a new machine,
and its own autosave overwrites the one from before the restart.
