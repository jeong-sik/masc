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

## Recruitment food boundary and merchant resupply

Inspect food before committing recruitment. In June 220 province 19,
soldiers 21, gold 750 and food 50 preceded a recruitment of 60 and allocation
of total 81 to Cao Ren. After confirmation, food displayed 65526, soldiers
81 and gold 150. That food value equals `(50 - 60) mod 65536`, but this
observation does not establish whether the cause is in the game or emulator.
Do not count the anomalous display as legitimate resupply.

A checkpoint replay at the same province resources recruited 50 instead,
allocated Cao Ren total 71, and confirmed with empty Return then `y`.
The resulting food was 0, soldiers 71 and gold 250. These observations
establish this input boundary, not a universal recruitment price or limit.
Preserve the failing checkpoint and receipt before restoring a comparison.

In that food-0 state, `13`, Return opened the merchant menu; `2`, Return
selected `米を買う`. The available officer list identified Xiahou Shang
as 2. `2`, Return opened `米をいくら買いますか(1-137)?`.
Entering `80`, Return returned to commands with food 80 and gold 104.
Use the visible menu, officer list and quantity range for the current state;
these indices and purchase cost describe this single observed transaction.

## Sell rice and reorganize an army

In December 220, province 10 held gold 1, food 1080 and troops 80.
Merchant `13`, Return → `1`, Return selected `米を売る`. Choosing the
available officer `1`, Return opened `米をいくら売りますか(1-1080)?`.
Entering `500`, Return returned to commands with gold 878 and food 580,
retaining troops 80. This sale's price is not a universal exchange rate.

Military `4`, Return → recruitment `1`, Return listed officer 1 in red;
selecting that index did not advance. Available officer `2`, Return opened
`何百人徴兵しますか(1-87)?`. Recruiting 80 and assigning officer 2 final
total 90 (previously 10), empty Return, `y` completed the allocation.
The province then held troops 160, gold 78 and food 500. Training `4`,
Return → `3`, Return selected available officer 3, martial 86, and `y`
confirmed the order; this sequence does not measure a numerical training gain.

To redistribute existing troops, military `4`, Return → `2`, Return
opens `再編成`. Choosing available operator `4`, Return opened allocation
with pool 0. Selecting officer `2`, Return, then total `0`, Return released
his 90 into the pool. Selecting officer `3`, Return, then total `100`, Return
combined that pool with his existing 10. Empty Return then `y` confirmed
reorganization. Province troops remained 160; own officer information
`8`, Return → `2`, Return → `3`, Return confirmed Niu Jin (`牛金`) at
troops 100, martial 86 and loyalty 63. Read the current roster and totals;
these indices belong to this province and month. A strategic officer panel
does not show training or armament.

## Transport supplies and verify arrival

At the province command, `2`, Return opens `どこに輸送しますか(1-41)?`.
In December 220, province 16 had gold 205 and food 442, while owned province
20 had gold 6 and food 20. Destination `20`, Return opened the transporter
list. Choosing officer `1`, Return asked for gold `(0-205)?`; `100`, Return
then asked for rice `(0-442)?`; `200`, Return opened `輸送しますか(Y/N)?`.
Confirming `y` displayed `無事に届けることができました`.

After continuing and returning to commands, province 16 showed gold 105
and food 242. Information `8`, Return → `1`, Return → `20`, Return showed
the destination at gold 106 and food 220, still troops 20. Thus both the
source deduction and destination receipt were verified. A confirmation
answer or source deduction alone is weaker evidence than the destination
resources. This proves one successful route, not guaranteed delivery for
all transports or a completed campaign. Allow screen transitions to finish;
if a key does not advance the expected prompt, step and inspect before
repeating an operation or restarting the machine.

## Buying weapons

At the province command prompt, `13`, Return opens the merchant menu when
available. In March 220, province 10 showed `4.武器を買う`; `4`, Return opened
an officer list headed `武器`. Sima Yi was number 1 with a displayed value of 1.
Choose from the current list, then send the officer number and Return.

The next prompt was `武器をいくら買いますか(1-99)?`. Separate `5`, `0`, Return
inputs entered 50 and returned to province commands. Gold fell from 450 to 400.
A later merchant officer list displayed Sima Yi's weapon value as 51.
The province officer information panel displays age, service, soldiers, loyalty,
intelligence, martial ability and charm; do not read its intelligence or other
attributes as training or armament. Use a labeled battle information panel or
an explicit action result to verify those values. This purchase establishes
weapon value 1 to 51, not a measured armament value or conversion formula.

Confirm the resulting gold and the selected officer's actual information before
claiming improved equipment. This observation does not prove improved combat
results. In a separate province-19 state, `13`, Return returned to the province
prompt without opening the merchant menu; no purchase was established there.

## Check battle armament and loyalty before another expedition

A February 221 province-20 → 21 inspection branch deployed Xu Huang and
Deng Ai (鄧艾), 100 troops each. Xu Huang's labeled battle information showed
training 33 and armament 0. Preserve that checkpoint before returning to
preparation; a large troop total alone does not establish that it is equipped.

After restoring the pre-sortie checkpoint, merchant weapon purchases of
100 for Xu Huang and 99 for Deng Ai (鄧艾) produced displayed weapon values 100
for each. A subsequent March sortie's labeled battle information confirmed
Xu Huang at troops 100, armament 100, training 144 and loyalty 96. This
verifies armament after that purchase. Training orders also occurred during
preparation, so the 33 → 144 comparison does not isolate a single training
order's gain or define a formula.

In that March battle, the March 4 summary changed own troops 200 → 100,
own officers 2 → 1, enemy troops 93 → 193 and enemy officers 1 → 2.
The enemy officer's identity and the cause were not obtained. Preserve the
branch; do not describe this as ordinary movement casualties, an emulator
fault or a proven loyalty mechanism from these totals alone.

Restoring the pre-sortie checkpoint and opening Deng Ai (鄧艾)'s own information
showed troops 100 and loyalty 68. Rewards `11`, Return → gold `1`, Return
opened the recipient list. Selecting Deng Ai (鄧艾) at the displayed index `5`,
Return, then `100`, Return deducted gold 618 → 518. His information then
confirmed loyalty 85, retaining troops 100. No confirmation question was
observed in this reward sequence. A later war selection list showed Xu Huang
in red and Deng Ai (鄧艾) available. Recheck the live departure list after rewards;
these observations do not promise that every prepared officer can depart in
the same month, that a reward prevents defection, or that loyalty gains are
fixed. The comparison branches did not establish a battle or campaign win.

In April, both officers were available and selected at 100 troops each.
After allocating gold 200 and rice 200, confirming dispatch and placing both
units, the first command summary showed own troops 100 and enemy troops
193. Inspecting Deng Ai's placement hex explicitly showed 孫権軍, troops
100, training 136, armament 100 and loyalty 90. This verifies his enemy
side membership after deployment; it does not isolate the cause of the
change or prove that the earlier loyalty-85 reward prevents it.

## Check numeric input before submitting

Held keys can repeat in numeric fields. During the May 221 province-21
retreat, `2` held for 5 frames entered `22`; a 1-frame tap was not accepted.
Separate 3-frame taps entered `2`, then `0`, and Return submitted the visible
`20`. These timings describe that prompt only. Observe the displayed number
before Return, and adjust the hold when a digit repeats or is missed; do not
infer the submitted destination from the intended key list.

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
- Guided movement `1` → `2` asks `どこに仕掛けますか?`. In an
  April province-21 branch, south `2` then opened the own movement direction
  prompt with mobility 4; north `8` moved Xu Huang and advanced the day.
  Subsequent information queries found Zhu Ran two hexes south, rather than
  one: the move succeeded, but enemy pursuit was not observed. No `0`
  placement input was needed between the two direction prompts.
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

## Locating an enemy before attacking through fire

A city's map symbol is not proof that an enemy occupies the selected hex.
In the October 220 province-19 assault, an early northwest normal attack did
not reduce the enemy total. A subsequent information selection showed no enemy
panel. Later, moving the information cursor and pressing `0` identified Guo
Huai: soldiers 43, training 85, armament 2 and martial ability 54. Confirm the
name and labeled panel before choosing an attack direction.

The same battle displayed `火を掛けられました` and spreading fire. Some attempted
movements did not change position even with displayed mobility 6; the exact
reason for each refusal was not isolated. On October 25 the fire was absent
from the observed screen. After moving south on a later turn, the totals were
own 98 and enemy 42 on October 27. This is a route observation, not a general
fire duration or a guarantee that waiting makes every hex passable.

At that position, separate `2` (attack), `1` (normal), `2` (south) inputs were
followed by October 28 totals own 98 / enemy 41. `2`, `4` (assault), `2` (south)
then led to October 29 totals own 91 / enemy 39, with changed positions. Inspect
positions again after an assault. These calls included animation and opposing
phases; the total changes do not isolate player damage, and assault was not a
loss-free improvement over normal attack.

After the October 30 turn, the game returned to province commands. Province-19
information still said `交戦中`: attacking Xu Shu troops 82, gold 90, food 901;
defending Sun Quan troops 38, gold 30, food 130. Returning to the strategic map
therefore did not prove victory, defeat or occupation. Check the war table and
observe the next month's actual battle resumption separately.

## Waiting for mobility and verifying occupation

A July 220 province-19 → 21 replay on native worker source
`afad361ff6f79b3d19e8c8c1b7d3c0926cab42cf` sent Cao Ren with 100 soldiers,
gold 100 and food 1,000. The initial battle showed friendly strength 100
and enemy strength 14. Cao Ren's labeled battle information showed soldiers
100, training 126 and armament 100. These current values do not establish a
training gain or a universal conversion from merchant weapons to armament.

- After two southward moves, normal movement displayed mobility 3 on day 3.
  South and southeast inputs left the unit and prompt unchanged. An unchanged
  movement prompt alone is not evidence that the emulator stopped.
- Return closed movement. Battle command `3` waited; after the next command
  menu finished drawing, `1` then `1` reopened normal movement. The displayed
  mobility was 4 on day 4 and 5 after another wait on day 5.
- Southeast digit `3` was accepted at mobility 5: the unit moved and the date
  became day 6. This verifies that crossing after waiting, not a universal
  terrain cost, mobility cap or route for other starting positions.
- After a further wait, day 7 displayed `孫権軍を全滅させました` and
  `朱桓を捕らえました`. No direct player attack was executed in this battle;
  the cause of the enemy's elimination was not established. Do not turn an
  enemy-phase result into claimed player attack damage.
- The prisoner screen offered recruitment, release and execution. Selecting
  recruitment with `1`, Return returned to the origin's command screen.
  The choice does not separately establish the prisoner's acceptance.
- To verify occupation from province 19, information `8`, Return → other
  province `1`, Return → `21`, Return opened province 21 with ruler Xu Shu
  and governor Cao Ren. It showed soldiers 109, gold 161, food 1,927 and
  three officers. Total soldiers alone do not identify their allocations.

Preserve the pre-expedition, labeled battle-information and post-occupation
checkpoints. These observations prove the local campaign transitions and
province capture, not unification or a completed winning campaign.

## Defending, retreating and checking arrivals

In the same campaign, leaving province 19 with no soldiers after the province-21
capture was followed by a Sun Quan counterattack. The notice showed attacking
strength 43 and food 58. An empty garrison still opened defender selection,
deployment and battle commands; it was not an emulator stall.

- Declining a foreign reinforcement request in a later province-18 defense
  opened the defender list directly. When a requested ruler was not accepted
  in the province-19 replay, empty Return left the ruler selector and opened
  `自力で切り抜けますか(Y/N)?`. Confirming `y` opened defender selection.
  A request or selected ruler alone does not prove reinforcement arrived.
- Select each defender with its number and Return, checking its `*` before
  ending the list with empty Return and the visible `y` confirmation. The
  governor was included without appearing in the additional-defender list.
  Province 19 selected eight additional officers and deployed nine.
- At the actual battle command prompt, `6`, then `y` opened a retreat
  destination prompt for each officer. Enter a displayed province number and
  Return for every officer; empty Return is not a destination. The set of
  destinations can differ between battles. Province 19 offered 10, 20, 11
  and 21; province 18's later defense offered only 16.
- After all nine province-19 officers selected 21, August province-21
  information showed 12 officers: its original three plus all nine retreating
  officers. Read both roster pages with `0`, Return where the list offers it.
  This confirmed those arrivals after defeat and normal campaign continuation.
- A later province-18 defense sent five officers toward 16. September
  province-16 information instead showed nine officers, with Sun Li, Li Dian,
  Lu Qian and Dian Man present but Zhang Hu absent. The total army was 140.
  All five destination answers did not establish five arrivals. The missing
  officer's fate was not verified; do not promise lossless retreat.

When an officer is absent from the retreat destination, inspect the lost
province and its current faction before declaring the officer dead or missing.
In June 221 province-16 defense, six officers answered destination 9 after a
forced retreat. July province-9's roster confirmed Zhang Liao, Sun Li,
Li Dian, Dian Man and Xiahou Hui, but not Lu Qian. Information from province 6
required an investigator before showing enemy province 16. Its ruler was
Sun Quan; the roster included Lu Qian and the former governor Dong Heng.
Their personal panels explicitly showed Sun Quan service: Lu Qian troops 10,
loyalty 43, and Dong Heng troops 1, loyalty 45. This verifies their later
faction and survival, not the cause or exact timing of transfer, a successful
retreat for all selected officers, or a campaign win.

An October province-21 counterattack also exposed a difference between
strategic and battle totals. The province had soldiers 9 and 11 officers.
After selecting a foreign ruler and Zhu Huan as reinforcement messenger, nine
additional defenders plus the governor deployed; every deployment entry showed
soldiers 0. The battle command screen showed own 0 / ten officers and enemy 93,
although the earlier attack notice had shown 100. Record both views without
inventing a rounding formula or treating strategic strength as battle strength.
Neither messenger selection nor a requested duel proved arrival or acceptance.

All ten defenders answered the only listed retreat destination, province 20.
The defeat message appeared, and November province-20 information showed ruler
Xu Shu, governor Xu Huang and ten officers. Both roster pages confirmed all ten
arrivals; Zhu Huan was outside this retreat group and his location was not
verified. The destination had soldiers 0, gold 290 and food 0. Buying rice 40
left gold 206 / food 40; recruiting 20 and assigning total 20 to Xu Huang left
soldiers 20 / gold 6 / food 20. Check food before recruiting, confirm allocation
and inspect final resources; arriving officers alone do not restore a garrison.

Preserve a checkpoint before defense, at the last retreat answer and after
reading the destination roster. Check ownership as well: defeat and successful
arrival of surviving officers do not preserve the original province.

When preparing the next expedition, inspect merchant weapons separately from
battle armament and training. A September province-16 purchase changed Zhang
Liao's merchant weapons 5 → 100 and gold 200 → 105. A subsequent Dong Heng
training action displayed `それぞれ訓練度が上がりました`; individual gains were
not measured. Capturing the screen soon after submission preserved that result
message; later province commands alone are weaker evidence of training.

## Battle defection work

In a March 220 province-21 battle, the current Xu Huang command accepted
`5` for work, then `2` for `寝返り`. This opened an enemy target list containing
Zhu Huan and Lu Meng. The target number uses a numeric entry field: `2` appeared
in that field, and Return submitted Lu Meng. Do not send a target number without
checking its displayed name; list positions depend on the current enemy force.

The next prompt asked `いかほど金を使いますか(0-78)?`. Separate `7`, `8` presses
entered 78; Return then opened `よろしいですか(Y/N)?`, and `y` confirmed the
attempt. The force had 78 gold in that observation. In an April 221
province-21 battle, the force had 190 gold but the prompt allowed only
`(0-100)`. Read the live amount range; do not assume its maximum equals
available funds or reuse another battle's amount.

In that April branch, choosing the explicitly listed Deng Ai (鄧艾),
entering 100 and confirming `y` showed `愚かなことを`, advanced the day,
and reduced own gold 190 → 90. Own troops 93 and enemy troops 183 stayed
unchanged. No allegiance transfer was observed; spending gold does not
establish successful persuasion.

In the March observation, after confirmation, the next own command was Yue Jin. Own gold fell from 78 to
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

## Ruler death, succession and a surviving retreat

A battle defeat can be followed by ruler death without ending the campaign.
In the manually played May 220 province-21 defeat, Cao Ren's retreat prompt
listed destinations 19 and 20. Entering `19`, Return produced
`曹丕軍は敗れました`; this names the defeated army and does not establish
that Cao Pi was captured. A subsequent report explicitly said
`君主の曹丕が死亡しました`.

Advance reports with `step` until an interactive prompt appears. At
`曹丕の後継者を選んで下さい(0-52)?`, the visible list identified Xu Shu
as number 6 with charm 85. `6`, Return produced
`徐庶が後を継ぎ君主になりました`. Use the current list; index 6 and the
selection range belong to that campaign state.

The next event was Sun Quan's marriage proposal, delivered by Zhuge Jin:
`1.承知する 2.断わる 3.捕らえる`. `1`, Return displayed a portrait and
retained the input; another Return advanced to June. This verifies the
acceptance input and event progression, not an alliance's duration or effects.

At the June province-6 command, `8`, Return, `1`, Return, `19`, Return
opened owned province 19's information. It showed Cao Xiu as governor and
soldiers 21, gold 750 and food 50. `2`, Return opened its officer list;
`10`, Return showed Cao Ren alive with soldiers 21. His loyalty was 64.
The province panel does not show training or armament. This proves one
survivor's return after defeat, not every officer's fate or a winning ending.

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
