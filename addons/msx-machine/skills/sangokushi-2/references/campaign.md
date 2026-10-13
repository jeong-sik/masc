# sangokushi-2 — Economy and campaign management

Part of the `sangokushi-2` Skill. Same caveat as the main file: these are observations
from a real campaign state; apply them only when the visible prompt matches.

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
