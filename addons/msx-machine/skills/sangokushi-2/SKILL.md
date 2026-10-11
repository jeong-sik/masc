---
name: sangokushi-2
description: "Sangokushi II (Koei 1990, Japanese, 3-disk set) on the shared MSX: media set and checkpoint compatibility, starting a new game, the province command menu, going to war, placing units (digits move, 0 places), battle commands and retreat, in-game save flow, media-change pitfalls, an all-AI run to the game's end, and one-call macros for the two verified key sequences. Apply a fact only when the visible prompt matches it."
---

# Sangokushi II

A turn-based strategy game played from three floppy images. Everything below
is an observation from a real campaign state, not a rule of the game: apply it
only when the visible prompt matches, and re-verify from the actual screen.

## Media

A = `sangokushi-2.dsk`, B = `sangokushi-2-b.dsk`, user data disk =
`sangokushi-2-data.dsk`. Catalog names only; no host paths. Start a fresh game or load your own in-game
save. A named checkpoint is local to its workspace and requires a compatible
emulator core. One older format-1 Cao Pi checkpoint restored a picture but reset
to C-BIOS after stepping on the newer core. A restored screenshot alone does
not prove a resumable game: verify continued input, and preserve an incompatible
checkpoint for its matching core rather than overwriting it.

## Province command prompt `(0-19)?`

Return with an empty entry reveals the command list; Space and F1 did not. A
numeric entry followed by Return selects that command instead.

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

Observed transitions: `1`, Return asks for a destination numbered 1-41; `9`,
Return asks which officer should develop the province. Neither alone proves
movement or improved land. `0`, Return, `y`, Return advanced the observed
campaign from province 10 to 18.

Development is a sequence of decisions: `9`, Return; read the officer list
and select an officer; capture the resulting amount prompt before entering a
cost. One observed province 13 action (officer 5, cost 50) changed gold from
500 to 450 and a displayed province statistic from 20 to 27, returning to the
command prompt with the month unchanged. That demonstrates a completed action
in that state, not a fixed exchange rate or a universally best officer.
Compare the actual before/after resources, then preserve the result before
planning another action.

Functions submenu cancellation: in one observed province 11 state, the
functions submenu `(1-6)?` remained visible after `0`, Return and after Esc.
A subsequent Return by itself returned to the same province's main `(0-19)?`
prompt with resources and month unchanged. Verify that prompt before sending
province commands; do not assume Esc universally cancels.

## Starting a new game

Observed 2026-09-29 from a fresh boot of disk A.

1. `何をしますか(1-3)?`: `1`, Return. `何番のシナリオですか(1-6)?`: the number,
   Return.
2. `第1ドライブにBディスクを入れ リターンキーを押して下さい`: change the disk
   to B (`masc_msx_change_disk`), then Return.
3. `何人でプレイしますか`, `プレイヤー 1 は誰を選びますか`, the level, other
   wars, the mode: number, Return each. `すべてよろしいですか(Y/N)?`: `y`.
4. An event screen can come first; Return goes on to the first
   `<君主>様、第N国に御命令を(0-19)?`.

## Alliance negotiation

At the province prompt, `6`, Return opens diplomacy; `1`, Return selects an
alliance. Wait for the complete ruler-selection prompt and read the list before
choosing a ruler, then select an available envoy. In the observed Cao Pi,
January 220, province-10 campaign, Liu Bei and envoy Cao Pi were each number 1.
At `使者を送りますか(Y/N)?`, `y` appeared in the field; Return submitted it.
The game reported the alliance concluded and returned to province commands.
Liu Bei's displayed hostility changed 50 → 30; gold stayed 950.

These numbers and success are specific to that campaign. Short input sequences
sent during the list transition did not reach the intended choice. Read the
complete prompt, send the digit, verify it in the field, then send Return.
The later alliance-break list was inspected and canceled with an empty Return
without choosing a ruler; opening that list did not itself break the alliance.

## Recruitment and training

At a province command prompt, `4`, Return opens `1.徴兵 2.再編成 3.訓練`.
The following sequence was observed in February 220, Cao Pi province 10;
choose from the current lists rather than reusing these officer numbers.

- Recruitment: `1`, Return asks who recruits. Sima Yi was available as 2.
  Selecting him opened `何百人徴兵しますか(1-95)?`, in hundreds of people.
  Entering 50, Return opened allocation with a pool of 50 in the displayed
  units; it did not finish the action.
- Allocation asks `だれを変更しますか(0-11)?`. Sima Yi's existing troops
  were 10. Selecting him asked for the new total `(0-60)?`; entering 60
  assigned the pool and showed Sima Yi 60 with remaining pool 0.
  `0`, Return showed the next officer page (9–11), rather than canceling.
  An empty Return opened `よろしいですか(Y/N)?`; `y` confirmed it.
- The resulting province prompt showed soldiers 200 → 250, gold 950 → 450,
  food 400 → 350, population 8000 → 7950, and loyalty 45 → 44. These are
  that action's before/after values, not a guaranteed exchange rate.
- Training: `3`, Return in the military menu asks which officer trains.
  The observed list showed martial skill and red unavailable officers.
  Selecting the available officer 6 opened the advisor's
  `訓練を始めますか(Y/N)?`. `y` returned to province commands. Reopening
  the trainer list showed officer 6 unavailable; no before/after training
  statistic was measured, so this does not establish a training increase.

## Buying weapons

At the province command prompt, `13`, Return opens the merchant menu when
available. In March 220, province 10 showed `4.武器を買う`; `4`, Return opened
an officer list headed `武器`. Sima Yi was number 1 with a displayed value of 1.
Choose from the current list, then send the officer number and Return.

The next prompt was `武器をいくら買いますか(1-99)?`. Separate `5`, `0`, Return
inputs entered 50 and returned to province commands. Gold fell from 450 to 400.
A subsequent information lookup (`8`, Return; `2`, Return; the current officer
number, Return) showed Sima Yi with soldiers 10, training 10 and armament 6.
The earlier merchant list and later officer information thus displayed 1 and 6;
the purchased amount 50 is not the displayed armament value. The exact conversion
rule and a general price formula were not established by this one purchase.

Confirm the resulting gold and the selected officer's actual information before
claiming improved equipment. This observation does not prove improved combat
results. In a separate province-19 state, `13`, Return returned to the province
prompt without opening the merchant menu; no purchase was established there.

## Going to war

Observed 220年1月 as 曹丕, from 20 against 31 (劉備).

1. `3`, Return: `どこへ攻め込みますか(1-41)?`; the province number, Return.
2. `誰を出撃させますか(1-N)?`: one officer per answer, the number and Return;
   a sent officer gets a `*`. Several can go. An empty Return ends the list.
3. `軍資金をいくらもっていきますか`, then `兵糧をいくらもっていきますか`: the
   amount, Return. `攻め込みますか(Y/N)?`: `y`.
4. When the governor left, `第N国の太守を決めて下さい(1-N)?` picks the new one.

## Placing units

`<武将>を配置して下さい(0:配置)` asks for one unit at a time. The battle map is
made of hexes and its cursor moves on the digit keys; arrow keys, `4` and `6`
did nothing. `0` places the unit on the cursor's hex.

The next unit can start on the occupied hex. Move to a permitted tile before
pressing `0`; an occupied, off-map or disallowed tile keeps the same prompt.
In one province-18 → 27 battle, `0` placed Zhang Liao, then separate presses
`1`, `8`, `0` placed Xiahou Dun. This is specific to that terrain and starting
cursor, not a universal placement macro. Inspect the PNG after every decision
and confirm the next officer or battle prompt before continuing.

## Battle commands

- A challenge such as `我が名は関索 いざ勝負せよ` asks
  `申し込みを受けますか(Y/N)?`. Return there went on to the battle menu.
- `1.移動 2.攻撃 3.待機 4.情報 5.工作 6.退却` and
  `<君主>様、<武将>にご命令を(1-6)?`: the digit alone opens the command, with
  no Return. A Return after it backs out of the menu the digit opened.
- `1` gives `1.通常移動 2.誘導移動`; `1` again asks `どの方向ですか?` with
  `機動力 N`. `2` moved the unit one hex down and spent the rest of its
  mobility, and the next unit's menu came up.
- `2` opens `1.通常 2.一斉 3.火計 4.突撃`. In the observed province-27
  battle, `1` then asked `どの方向ですか?`. Choosing direction `9` returned
  a partly drawn command menu; a later Return exposed the next officer's command
  prompt. The displayed troop totals did not change, so this does
  not establish an enemy hit or a universally valid attack direction.
- `4` asks `誰の様子を見ますか? (0:見る RET:やめる)`. Move the information
  cursor with the hex-direction digits, then press `0` to inspect the officer
  on that hex. This is an information cursor, not a troop movement command.
  In the March 220 province-21 battle, `0` first showed Yue Jin's panel:
  soldiers 10, training 53 and martial ability 86. Separate `2`, `2`, `0`
  inputs then showed Xu Huang: soldiers 50, training 61 and martial ability 92.
  That sequence depends on the current positions; it is not a universal way to
  select Xu Huang. Confirm the displayed name before using the numbers.
  `RET:やめる` indicates Return to leave. Inspect the resulting command prompt
  before sending another command. Current training values do not establish a
  training gain, and soldier values use the game's display units.
  After a later cursor sequence and `0`, Xu Huang's panel remained displayed.
  Retained information alone does not identify the selected hex or establish
  that an enemy occupies it.
- `6` asks `全軍退却しますか(Y/N)?`; after `y` each unit asks
  `<退却>:20 <武将>はどこに退却しますか?`. Type the province number shown and
  Return; an empty Return is not an answer. After the last unit the map comes
  back with the next province's command prompt.

## Battle defection work

In a March 220 province-21 battle, the current Xu Huang command accepted
`5` for work, then `2` for `寝返り`. This opened an enemy target list containing
Zhu Huan and Lu Meng. The target number uses a numeric entry field: `2` appeared
in that field, and Return submitted Lu Meng. Do not send a target number without
checking its displayed name; list positions depend on the current enemy force.

The next prompt asked `いかほど金を使いますか(0-78)?`. Separate `7`, `8` presses
entered 78; Return then opened `よろしいですか(Y/N)?`, and `y` confirmed the
attempt. That maximum was the force's current gold, not a general input limit.
Read the amount prompt rather than reusing the observed maximum in another battle.

After confirmation, the next own command was Yue Jin. Own gold fell from 78 to
0, while displayed troops and officers remained enemy 128 / two and own 103 /
four. This establishes target selection, payment and command progression;
it does **not** establish a successful defection or faction transfer. Verify an
actual result and the target's subsequent faction before claiming success.

## A battle continuing into the next month

In a manually controlled Cao Pi campaign, province 20 attacked province 21
in January 220. After the January 30 battle command, the game returned to
province commands. That return did **not** establish a completed battle:
February's information screen still listed both sides at province 21.
The defending Sun Quan force showed 231 soldiers and five officers; the
attacking Cao Pi force showed 46 and one officer, gold 110 and food 91.
These are the game's displayed units, not exact individual casualty counts.

At the current province command, `8`, Return opens information. `1`, Return
asks which province to inspect. An owned province's resources were displayed
directly. Inspecting foreign province 21 required choosing an investigator;
after that officer's number and Return, the ongoing battle table appeared.
An empty Return canceled the investigator selection in a separate observation.
Read the current prompts rather than assuming every inquiry is a free lookup.

To reinforce that ongoing battle from province 20, `3`, Return, then `21`,
Return opened the officer sortie list. Chen Tai was the only officer, number 1,
with soldiers 10. Selecting him and ending selection with an empty Return
opened gold and food entry. Gold 100 and food 50 were each visibly verified
before Return; the final prompt was `応援部隊を派遣しますか(Y/N)?`.
`y` dispatched the reinforcement and returned to province commands.

After the remaining February province commands ended, the same battle resumed
on February 1 with Chen Tai's placement prompt. `0` placed him on a permitted
hex. The battle then showed soldiers 56, two officers, gold 210 and food 141:
the increases matched the dispatched soldiers 10, one officer, gold 100 and
food 50. A later explicit Chen Tai command accepted normal movement south and
advanced the battle date. Dispatch, arrival, placement and controllable movement
are separate observations; confirm each before calling a reinforcement joined.

For combat evidence, preserve the command screen, attack direction prompt and
short successive observations. In the observed February 10 battle, Xiahou Wei's
`2` attack, `1` normal, direction `2` south was followed by displayed enemy
soldiers 235 → 233 and own soldiers 30 → 28 while the date remained February 10.
Only later did February 11 and the opponent Zhu Huan's tactical label appear.
Longer 300-frame calls can include the next opposing phase, so their final troop
difference alone does not isolate the player's attack. This proves an observed
attack-associated reduction before the next opposing phase, not exact casualties,
a victory, or a completed winning campaign.

## In-game save

`1`, `9`, Return, then `5`, Return (command 19 機能, option 5) opens the save
flow. Swap to the data disk only when the game requests D; follow the slot
and name prompts; swap back to B when requested. Emulator checkpoints and the
game's own save/load are distinct behaviors to verify separately.

To retain the game's changed disk as reusable media, wait for the completed
write / return-to-B prompt and call `masc_msx_export_disk` **while D is still
mounted**, with a new `filename`, for example `campaign-data-01.dsk`. Check the
returned filename, byte count and SHA-256. Existing names are refused. Only
then swap back to B as requested. Exporting after the swap would copy B instead.

To verify the save independently of an emulator checkpoint, fresh-boot A,
choose title option `2`, Return, insert the exported data disk when D is
requested, choose the saved slot with Return, and insert B when requested.
Read the restored ruler, date, province and resources, then verify a command
still opens. This round-trip was observed for Cao Pi, January 220, province 10,
gold 950 and land 72 on native worker source `1632107405d574726b90f0ac918ceeaf98ddbbcb`.


## Media-change pitfall

A controlled replay found that switching from B to A during an active
campaign cleared the open file state while the game still needed
`PACKDATA.DAT`, which was present on B. Replaying the same accepted inputs
from the same earlier checkpoint while retaining B reached a readable
diplomacy prompt. That is a failure of one media-change sequence, not a rule
to keep B inserted at all times: follow the currently visible D or B request
when the game asks.

## Reading the screen

Bitmap modes (GRAPHIC6 openings and scenes) leave name-table residue:
`screen_text` there is not OCR of the visible scene. Read the PNG image returned by the attached `masc_msx_screen` tool. The
Add-on’s `msx-observe` Skill explains how to preserve the captured frame
and report uncertain text.

## Advancing the campaign month

Ending one province's commands does not by itself advance the month. At the
visible province `(0-19)?` prompt, send `0`, Return, then confirm `y` at
`今月の命令を終えますか(Y/N)?`. Read the next screen before repeating: it may
be another owned province, a report, or a different interactive prompt.

In an observed scenario 6 campaign, January 220 command menus visited
provinces 10, 18, 6, 14, 20, 2, 16, 17, 3, 19, 7, 9, 13, 12, 5, 11, 8 and 4.
After the last command end, the date changed to February 220. Subsequent AI
reports progressed with `masc_msx_step` alone, and Cao Pi's province 10 command
menu returned with gold 950 and land 72. This order describes that saved
campaign; choose each action from the current screen rather than replaying
the province list on another campaign.

During reports, advance without injecting an unrequested key and inspect the
PNG. A date change plus the next human command menu verifies month progression;
a province number change within January does not. This replay used native
worker source `1632107405d574726b90f0ac918ceeaf98ddbbcb` and proves one campaign
month, not victory or a normal winning ending.

## Watching an all-AI game

`0` at `何人でプレイしますか` starts with no human ruler and goes straight to the
AI turns. Pressed with Return every 300 frames, one scenario 6 run went from
220年 to 301年, when the last ruler died without an heir
(`曹爽の一族は滅亡しました`) and the KOEI copyright screen came up. That is
the game ending with no winner, not a victory; no full winning campaign is
established.

## Repeated sequences

- Ending the current province's commands (`0`, Return, `y` at the province
  `(0-19)?` prompt) is one call: the `sangokushi-2-end-command` composition
  Skill presses the verified sequence, waits for the settled screen and
  returns the observation. This is the verified province 10 to 18 transition.
- The save-flow entry is `1`, `9`, Return, `5`, Return at the province
  prompt: one `masc_msx_press` call with `sequence=true`. The disk prompts
  that follow are interactive: read the screen and swap media per the visible
  request; nothing pre-swaps disks.
