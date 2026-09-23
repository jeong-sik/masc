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

`keys_pressed` below the number you sent means the call reached its step
ceiling; the rest never reached the machine.

## Saves

When the game writes a file (its own save), the lane keeps it under
`<.masc>/dos/saves/<program>/` and mounts it at the next load, so an in-game
save survives an eject or a server restart. Save through the game's own menu
before a long pause. A save that did not reach disk is listed in `unsaved`
on the call that wrote it; the call itself still happened.

## Loading

`masc_dos_load` with no `program` lists the inventory. A game directory with
several programs needs `boot` (for example `KOEI.COM`). Loading replaces the
machine: never load over a game someone else is playing.
