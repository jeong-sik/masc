# sangokushi-2 — Battle operations

Part of the `sangokushi-2` Skill. Same caveat as the main file: these are observations
from a real campaign state; apply them only when the visible prompt matches.

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
