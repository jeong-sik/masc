---
name: sangokushi-3
description: "삼국지 III (Koei 1993, Korean) on the shared DOS machine: boot with KOEI.COM, the copy-protection code, the numbered prompts from main menu to the first ruler's turn, going back and fixing a typed number, a 2-player hotseat, ending a month, going to war, placing officers (digits move, 0 places), battle commands, saving, the ending, and watching an all-AI game. Apply a fact only when the visible prompt matches it."
---

# 삼국지 III

Everything below is an observation from real runs on the DOS lane, not a rule
of the game. Apply a step only when the screen shows the prompt it names, and
read the screen (returned PNG image) after every decision. The general DOS lane
rules — controller, passing, saves — are in the `dos-play` Skill.

## Timed transitions and explicit input execution

A controlled battle replay on worker source `1632107405` returned
`settled: true` after one Space and 350,000 instructions, with two empty keyboard
polls, while the command menu was absent. With no further key, running another
4,000,000 instructions displayed “유비님, 명령을(1–9)?”. A control restored the
same checkpoint and ran 350,000 plus 4,000,000 instructions without any key;
the menu appeared there too. This demonstrates that an ordinary timed transition
can outlast the settling observation. It does not establish that Space caused
the transition or that every transition needs that instruction count.

When a visible prompt calls for one key and the default call returns too early:

1. Send only that key with an explicit run, for example
   `masc_dos_press {"keys":["space"],"until_ready":false,"steps":4000000}`.
   Choose the key from the current prompt; this example does not authorize Space
   on an unknown screen. `masc_dos_type` supports the same mode but sends only
   its first character.
2. Read `masc_dos_screen` and inspect its PNG. This mode reports `settled: false`
   regardless of which screen it reaches. It guarantees the requested run
   allowance unless the program exits, not a final prompt.
3. If the transition remains visible, advance with `masc_dos_step` and
   `until_ready: false`, then inspect again. Do not repeat an already delivered
   key just because the picture was unchanged.

The default batch mode is unchanged and still uses the settling observation
between keys. `keys_pressed` identifies the delivered prefix; in explicit-run
mode every later key or character is unsent. A still “어느 부대입니까?” selection
screen after a digit or time advance can also mean that the selection needs a
different input. Screen identity or elapsed instructions alone do not prove
that the game accepted a command.

## Boot

`masc_dos_load` with `program: samguk3`, `boot: KOEI.COM`. KOEI.COM runs the
opening (OPEN.EXE) and then the game (MAIN.EXE). The KOEI logo waits for a
key; `enter` skips the opening.

## Copy protection

A white box: `CODE:` / `INPUT CODE [孫李呂]`, three red hanja. The code for
`[孫李呂]` is `10183`: `masc_dos_type` `10183`, then `enter`.

Type the code only once the box is on the screen. After the key at the KOEI
logo the screen can report settled while black; run `masc_dos_step` with
`until_ready: false` and inspect the PNG until the box
shows. Digits typed into that black screen move the question: in one run the
box then asked `[馬李袁]`, the typed code was wrong, and the loader printed
`MAIN.EXE : fatal error occurred.` and exited. If the box shows other hanja,
the code is not known here — ask the operator rather than guessing, since a
wrong code ends the program.

## Keys depend on the visible prompt

Use the screen-specific steps below. A `(range)?` label alone does not tell
whether a digit needs `enter` or what an empty `enter` will do.

- Number then `enter` was observed for ending a ruler's month, the war
  destination, officer and unit-type choices, gold and food amounts, the
  officer carrying food, and the save-slot number. Follow their named steps.
- Empty `enter` closed the 군사 submenu and gold prompt in the observed run.
  In the war officer list it returned to the command prompt while nobody was
  sent yet; once an officer has a `*`, it ends the list, and the next prompt
  is the commander selection (`누구를 총대장으로`) when the run asks for one
  or the gold amount — do not type a resource amount into the commander
  prompt.
  At `어떻게 하겠습니까(1-3)` in the save menu, it returns to the command
  prompt.
- Battle-menu digits act immediately; a following `enter` backs out of the
  menu just opened. During officer placement, `enter` does nothing and `0`
  places the officer. Read those sections before sending another key.
- `backspace` deletes the last typed digit where that was observed (`55`
  became `5` at a resource prompt). At the commander prompt it had not
  visibly cleared the field: read the field before `enter` there.
- `esc` does nothing. At eight prompts — command, submenu, officer list, gold,
  battle menu, move direction, attack type, attack target — the screen stayed
  the same.
- At the command prompt `space` hides and shows the information panel. While
  the panel is hidden, the next key only brings it back and is not typed; read
  the screen before typing the command.

## From the title to the first turn

In the isolated native-worker run, the initial numeric menus required the
number **then `enter`**, including new game, scenario, player count, ruler,
level, other wars and mode. The table names choices, not complete key sequences.
Read the resulting prompt before the next choice; battle-menu digits below
behave differently.

| Prompt | Observed choice |
| --- | --- |
| 마우스를 사용할 경우에는 클릭해 주세요 / 키보드… 키를 눌러 주세요 | any key (`space`) |
| 어느 것을 하겠습니까(1-3)? — 1 새로운 게임, 2 데이터 로드, 3 장수 등록 | `1` |
| 몇번의 시나리오입니까(1-6)? | `1` (189년, 동탁 폭정) |
| 몇 명으로 게임하겠습니까(0-8)? | the number of human players; `0` lets every ruler be AI (spectating) |
| 게임자 N은 누구를 선택하겠습니까(0-19)? | one per human player; in scenario 1: 1 공손찬, 2 원소, 3 유비, 4 한복, 5 조조, 6 도겸 … |
| 게임레벨은 어느 것으로 하겠습니까(1-2)? | 1 초급, 2 상급 |
| 타국의 전쟁을 보겠습니까(1-2)? | `2` keeps AI wars off the screen and the calls short |
| 게임모드는 어느 쪽으로 하겠습니까(1-2)? | 1 사실모드, 2 가상모드 |
| 모두 좋겠습니까(Y/N)? | `y` |
| 그러면 게임을 시작합니다 | `enter` |

## A ruler's turn

`<군주>님, <번호>.<도시>에 명령을(0-9)?` — the top bar lists 0 휴양, 1 군사,
2 인사, 3 외교, 4 정보, 5 개발, 6 계략, 7 상인, 8 특별, 9 기능. The name at the
start of the prompt is whose turn it is.

`0`, `enter` asks 이달의 명령을 끝내겠습니까(Y/N)?; `y` ends that ruler's month.
The `sangokushi-3-end-month` composition does the three keys in one call.
Every city the ruler commands takes its own turn in the same month, so the
prompt comes back with the next city's number.

## Going to war

Observed 2026-09-29 in scenario 6 as 조예, from 17 하비 against 33 건업.

1. `1` (군사), `enter`. In the list `4.전쟁` is red when no enemy city borders
   this one; pick a border city instead.
2. `4`, `enter` asks `어느 곳으로 쳐들어가겠습니까(1-68)?`; arrows on the map
   mark the neighbours. Type the city number, `enter`.
3. `누구를 보내겠습니까(1-N)?`: one officer per answer — the number, `enter`,
   then the unit type `1.보병 2.기마 3.노궁 4.강노`, number, `enter`. A type
   the city cannot field answers `그 부대는 안됩니다`. A sent officer gets a
   `*`. Several officers can go; an empty `enter` ends the list.
4. If `누구를 총대장으로 하겠습니까(1-N)?` appears after ending the list,
   choose a commander from the displayed expedition officers, then `enter`.
   Inspect the following commander confirmation and answer `y` if correct;
   the observed Xiahou Dun selection required this before the gold prompt.
   In the February 189 Chenliu-to-city-9 preparation with Xiahou Yuan and
   Xiahou Dun, this prompt appeared before any resource amount. Do not type
   gold into it. An observed out-of-range `5` followed by Enter abandoned
   that preparation and returned to the campaign menu; it did not launch a
   battle. Backspace had not visibly cleared that field.
5. Only when the resource prompts are visible, enter gold and then food,
   each amount followed by `enter`. Then answer the visible
   `처들어가겠습니까(Y/N)?` confirmation with `y`.

## Placing officers for a battle

Observed at 193년 7월 6 평원 (유비 defending against 원소) and at 235년 1월
33 건업 (조예 attacking), both on 2026-09-29.

- `<장수>를 배치해 주세요` places one officer at a time on the battle map.
  The map is made of hexes, and a blinking cursor starts on a free one.
- Move the cursor one hex per press with the digit keys: `8` up, `2` down,
  `7` up-left, `9` up-right, `1` down-left, `3` down-right. Arrow keys, `4` and
  `6` do nothing here.
- `0` places the officer on the cursor's hex, and the prompt names the next
  officer. A hex that is taken, walled, or outside the side's area refuses
  `0` and the prompt stays; move one hex and press `0` again.
- `enter` does nothing at this prompt. A screen that still asks after `enter`
  is waiting for `0`, not frozen.
- The attacker then answers `누가 군량을 가져 갑니까(1-N)?`: number, `enter`.

## Battle commands

`1.이동 2.공격 3.대기 4.계략 5.정보 6.퇴각 7.출진 8.위임 9.기능` and
`<군주>님, <장수>에게 명령을(1-9)?`. Red items cannot be chosen.

- A battle menu takes its digit alone, with no `enter`. An `enter` after it
  backs out of the menu the digit opened.
- `1` (이동) asks `어느 방향입니까?` with `남은 기동력`. Each digit moves one
  hex in the directions above and spends mobility; at 0 the next officer's
  menu comes up.
- `2` (공격) opens `1.통상 2.일제 3.기습 4.화살 5.불화살 6.돌격 7.일기토`;
  after the type, `어느 곳입니까?` takes a direction digit. An empty hex
  answers `적은 없었습니다`.
- `3` (대기) ends the officer's move; `<장수>의 기동력이 N가 되었습니다` waits
  for any key.
- `8` (위임) asks `전군위임합니다 해제할 수 없습니다만 좋겠습니까(Y/N)?`; `y`
  hands every officer to the computer until the battle ends. Each
  `<장수>의 전술` line still waits for a key (`space`). One delegated siege ran
  from day 1 to day 10 and returned to the attacker city's command prompt.

## Hotseat

With two human players (유비 and 조조 in scenario 1) the game asked 조조 first
in 189년 봄 1월, and after 조조 ended the month the next settled screen asked
유비 — the AI rulers' turns ran inside that one call. When the prompt names a
ruler played by another Keeper, pass the controller to them (`dos-play`).

## Saving and loading inside the game

The game has ten save slots of its own, shared by every human player. They
are the game's files, so they outlive an eject and a server restart. In
the answer of the call that pressed `enter`, an empty `unsaved` list means
every file the game wrote in that call reached disk. The machine checkpoint
in `dos-play` is separate and also keeps a turn that is half done.

Save, at a ruler's command prompt (`<군주>님, <번호>.<도시>에 명령을(0-9)?`):

1. `9`, `enter` (기능), then `1`, `enter` (중단). The 끝/저장/로드 menu opens.
2. `2`, `enter` (저장). The slot list shows `1.`–`10.`; a filled slot names the month,
   ruler and city, for example `3.189년 2월:조조 :진류`.
3. Type the slot number, then `enter`.
4. Open the list again (steps 1–2) and read the slot's line. That is how you
   know the write happened. Leave with an empty `enter` at
   `어떻게 하겠습니까(1-3)`, which returns to the command prompt.

In that menu `esc` does nothing, and `1.끝` may leave the game, so do not
press it. Read the list before you write: use an empty slot or one that names
your own ruler, never the other player's. When all ten are full, agree with
the other Keeper on which slots each of you overwrites.

Load, at the title menu `어느 것을 하겠습니까(1-3)?`: `2`, `enter` (데이터 로드), then the
slot number, `enter`. The screen goes black while the game reads; call
`masc_dos_step` until it settles, then `space`. After a server restart with
no `autosave` to restore, this is the way back: boot, pass the copy
protection, then `2`.

## The ending

Keep the ending assets with your game: `END.EXE`, `ENDSTIL.DAT`, `KOEI.DAT`
and `FMDRV.COM`. A missing `ENDSTIL.DAT` produced `END.EXE : file access failure.`
in an earlier installation. Confirm the inventory instead of assuming every
copy of the game includes the ending data.

A separate native-worker probe on source
`1632107405d574726b90f0ac918ceeaf98ddbbcb` used ordinary DOS `EXEC` calls to load
the sound driver and unchanged ending executable. It displayed character
scenes, Korean narrative and the copyright screen, then exited with code 0
after Space on that screen. This verifies the renderer and assets, not a
winning campaign or the normal `MAIN.EXE` transition into the ending. Continue
normal play through `KOEI.COM`; directly loading `END.EXE` does not reproduce
the parent process and resident-driver setup.

In the observed game where every ruler's clan died out, the KOEI copyright
screen appeared and a key exited.

## Watching an all-AI game

`0` players starts a game with no human ruler: 표시군주 `n`, and the months run
on `space`. Every AI war is shown on the battle map, and each `<장수>의 전술`
line waits for a key.

## Battle information and input device

At the visible human battle command menu, `5` opens information and offers
`1.아군장수 2.적장수`. In keyboard mode, choose friendly `1`; with the cursor
on the acting unit, `0` opened Liu Bei's information panel in an observed
battle. The panel showed troops 1614, morale 94 and training 50. Space closed
it to unit selection; Enter returned to the friendly/enemy choice and another
Enter returned to the command menu. This is a positive control for one friendly
unit, not evidence that an arbitrary selected cell contains an enemy.

The enemy selector's cursor moved with numeric directions in that replay:
`1` moved down-left, `3` down-right and `2` down. Inspect the marker after each
input. Selecting the examined blue structure cells with `0` did not reveal
an enemy officer. Do not identify buildings, blinking markers or changes in
total army strength as individual enemies or manual damage.

Battle command `9` offers `1.표시시간 2.입력장치`. Input-device option `2` then
offers mouse `1` or keyboard `2`. To enable the mouse in the observed keyboard
mode, send `1`, Enter, and answer `y` only when the mouse-change confirmation
is visible. These settings prompts need Enter even though ordinary battle
commands open with a digit alone.

After switching, `masc_dos_click` with `buttons: 1` selected information, the
friendly side and the acting unit, opening the same Liu Bei panel. Select
coordinates from the current PNG; the replay's coordinates are not a layout
contract. The panel asked for a mouse click; a left click dismissed it.
A right click (`buttons: 2`) backed out of unit selection, and a second right
click backed out of the side menu. The resulting checkpoint remains in mouse
mode. A click that does nothing in keyboard mode is not evidence of a broken
mouse emulator. This replay used worker source
`b19d338c19f5db83705e4999f6111f6e10f60ac5`; it does not prove battle victory or
a completed campaign.
