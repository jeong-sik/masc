# sangokushi-3 — Battle commands and information

Part of the `sangokushi-3` Skill. Same caveat as the main file: these are observations
from a real campaign state; apply them only when the visible prompt matches.

## Battle commands

`1.이동 2.공격 3.대기 4.계략 5.정보 6.퇴각 7.출진 8.위임 9.기능` and
`<군주>님, <장수>에게 명령을(1-9)?`. Red items cannot be chosen.

- A battle menu takes its digit alone, with no `enter`. An `enter` after it
  backs out of the menu the digit opened.
- `1` (이동) asks `어느 방향입니까?` with `남은 기동력`. Each digit moves one
  hex in the directions above and spends mobility; at 0 the next officer's
  menu comes up. Read the remaining value after each move: in the
  February 189 Puyang battle, two northward moves changed Xiahou Dun
  from 4 to 2 to 1; another was refused with `기동력이 부족합니다`.
  Acknowledge that notice with `space`. With no movement spent, an empty
  `enter` closed the direction prompt and returned to the same officer
  command menu. A refusal alone does not identify the terrain or its cost.
  After a successful partial move, `enter` can instead end that officer's
  turn: in January 190 Puyang, Cao Ang moved north with mobility 4 remaining,
  then `enter` opened Li Dian's command. `0` retained the direction prompt
  in this battle; do not reuse the deployment placement key as a movement
  commit key. Identify the active officer from the bottom command text.
  The upper-right commander name remained Xiahou Yuan across both turns.
- `2` (공격) opens `1.통상 2.일제 3.기습 4.화살 5.불화살 6.돌격 7.일기토`;
  after the type, `어느 곳입니까?` takes a direction digit. An empty hex
  answers `적은 없었습니다`.
- `3` (대기) ends the officer's move; `<장수>의 기동력이 N가 되었습니다` waits
  for any key. Waiting can build mobility for a later turn: in the same
  Puyang battle, successive waits displayed Xiahou Yuan mobility 5, 6,
  and 7, and a later direction prompt retained the higher value. Use the
  displayed value instead of assuming that every turn resets it to 4.
  This observation does not establish a universal cost for crossing walls.
- Movement into enemy contact can open `공격하시겠습니까(Y/N)?`.
  At January 190 Puyang, Li Dian answered `n` after approaching Guo Si;
  the next officer command opened with both army totals unchanged. This
  allows approaching support without accepting the immediate attack.
- Movement can also trigger an enemy surprise attack. At February 190
  city-20 defense, Cao Hong's north `8` movement changed friendly troops
  4,021 → 3,695 while enemy troops stayed 5,856. Replaying from the saved
  command with 10,000 steps for the direction input, then short observations
  (100,000 steps and later 1,000,000), exposed `앗! 적병이다` followed by
  `적의 기습을 받았다!`. Preserve the resulting branch before restoring the
  pre-action checkpoint to inspect a missed event. A later command screen
  and troop difference alone do not identify the cause of a movement loss.
- For a verified enemy hex, attack `2` → joint `2` → direction executes
  an 일제 attack when the menu allows it. From the same January 190
  day-6 noon checkpoint, Xiahou Yuan's north `8` joint attack inflicted
  429 enemy losses at 521 friendly losses; normal `1` north `8` inflicted
  149 at 303. These are one paired observation, not a universal damage
  formula or proof of which support officers participate.
- Read attack losses after the combat animation finishes and the next
  officer's command opens. A step-limited input response can capture an
  intermediate frame: on January 190 day 8 at noon, northward charge
  (`2` → `6` → `8`) first showed friendly/enemy totals 9,366/13,285,
  then finished at 8,920/13,168. From the same restored starting totals
  10,436/13,506, joint attack finished at 9,985/13,133. This comparison
  favors joint attack in that state only; it establishes neither a general
  combat formula nor victory. Observe again without sending another
  officer command when combat is still drawing.
- `8` (위임) asks `전군위임합니다 해제할 수 없습니다만 좋겠습니까(Y/N)?`; `y`
  hands every officer to the computer until the battle ends. Each
  `<장수>의 전술` line still waits for a key (`space`). One delegated siege ran
  from day 1 to day 10 and returned to the attacker city's command prompt.

## Battle information and input device

At the visible human battle command menu, `5` opens information and offers
`1.아군장수 2.적장수`. In keyboard mode, choose friendly `1`; with the cursor
on the acting unit, `0` opened Liu Bei's information panel in an observed
battle. The panel showed troops 1614, morale 94 and training 50. Space closed
it to unit selection; Enter returned to the friendly/enemy choice and another
Enter returned to the command menu. This is a positive control for one friendly
unit, not evidence that an arbitrary selected cell contains an enemy.

In the later Puyang defense, enemy information identified Dong Zhuo's Guo Si:
soldiers 14,804, training 62 and morale 75. The lookup was followed by own gold
2,760 → 2,750. Leaving that information flow required the visible
`끝내도 좋겠습니까(Y/N)?` confirmation; `y` advanced from Xiahou Yuan to Cao
Ang's command. Inspect the actual exit prompt: enemy inspection in this case
was not a free lookup that returned to the same acting officer. No general
cost or exit rule for all information commands is inferred.

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
