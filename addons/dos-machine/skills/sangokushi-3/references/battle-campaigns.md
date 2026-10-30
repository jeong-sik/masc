# sangokushi-3 — Sieges, captures and defence

Part of the `sangokushi-3` Skill. Same caveat as the main file: these are observations
from a real campaign state; apply them only when the visible prompt matches.

## Castle capture can force retreat after a wait

In February 190 city-20 defense, waiting with Xiahou Dun and then Cao Hong
was followed by `조조군의 성이 함락되었습니다`. The next prompt asked where
to retreat Xiahou Dun, although friendly troops remained 3,695 and enemy
troops 5,856. A long observation reached the retreat selector without
retaining that transient capture notice. Do not infer a misrouted command
or voluntary retreat solely from the later destination prompt.

Preserve the resulting checkpoint, then use short observations from the
pre-action checkpoint to inspect missed messages. In this replay, separate
100,000-step observations and a later 1,000,000-step observation exposed
Cao Hong's mobility notice and the castle-capture notice. These intervals
are observations from this branch, not a required timing rule.

The destination list offered only `10.진류`. Each named officer answered
with `1`, `0`, Enter: first Xiahou Dun, then Cao Hong. The game reported
`조조군은 패배했습니다`, resumed AI strategy turns, and reached March
Chenliu commands. Its own roster confirmed both officers present. Answering
a destination alone does not prove arrival, and arrival does not preserve
the lost city or establish a campaign win.

## A manual siege, an ongoing battle and reinforcements

A native-worker replay on source
`daece6c0facc64524ad49a1c1bc2f60c173a25d4` completed the March–April 189
Chenliu → Puyang siege with explicit key inputs. These are observations from that
campaign, not universal gate costs or reusable coordinates.

- Xiahou Dun approached the southwest gate with infantry. At his command
  menu, `2` → `1` → `8` attacked the gate to the north. Subsequent gate
  displays reached 31, 14 and 0. After zero, movement `1` → `8` crossed
  the gate, then `9` moved into the city. A displayed zero alone is weaker
  evidence than the observed unit crossing; inspect both.
- Later movement into contact asked `공격하시겠습니까(Y/N)?`. `y`
  executed the attack: defenders changed 7,500 → 7,175 and attackers
  12,300 → 12,010. Read the current target and confirmation. Enemy movement
  changed the valid attack direction later; do not repeat a fixed direction
  across turns without checking the map.
- The March battle ended with `승부는 다음달로 넘어갔습니다`. This is
  an ongoing battle, not victory. Finish the remaining city commands and
  resolve actual month-end events to reach the next month's commands.
- In April, Chenliu military `1`, Enter → war `4`, Enter → destination
  `9`, Enter offered `응원부대를 보내겠습니까(Y/N)?`. `y` opened the
  officer list. Select an available officer and unit type with Enter at
  each prompt; an empty Enter ends the selected officer list. The gold,
  food and final expedition confirmation follow their visible prompts.
  Sending Cao Hong's 2,000 infantry, gold 300 and food 12,000 decreased
  Chenliu soldiers 11,200 → 9,200 and food 25,000 → 13,000.
- Ending Chenliu's April commands resumed the battle. The reinforcement
  needed placement on a permitted hex before `0` would accept it. Its cursor
  initially stood outside that area, so pressing `0` there did not place it.
  The next command screen then included the reinforcement's soldiers.
- The April battle displayed enemy strength 0, an enemy-annihilation notice
  and then `조조군의 승리입니다`. The captured ruler's disposition was
  another interactive prompt; releasing him required choice `1`, Enter
  and the visible `y` confirmation. After Chenliu's May commands ended,
  Puyang's own command screen named ruler Cao Cao and governor Xiahou Dun.
  This proves that battle and city capture, not unification or the ending.

Preserve a checkpoint before month rollover and another after capture.
Check the victory message and the captured city's ruler/command prompt;
returning to a map alone also happens when a battle is deferred.

## A field victory followed by city capture

The same native-worker replay later sent Puyang's army toward city 20, 초,
in October 189. Kong Zhou counterattacked on field 53, 정도. This opened a
field battle instead of the destination city's siege.

- The expedition selected Xiahou Dun and Xiahou Yuan, then requested a joint
  expedition from Chenliu. Cao Ren's 2,100 infantry arrived on day 2: the
  friendly total changed 7,281 → 9,381 and a Cao Ren command followed.
  Sending a joint expedition is not proof of arrival; inspect the battle.
- By day 7, attacks toward the earlier enemy position left the displayed
  totals unchanged. On day 8 the enemy appeared farther northeast, and
  Xiahou Yuan's northwest normal attack changed enemy strength
  1,796 → 1,693. Directions belong to current positions, not officers.
- Cao Ren's subsequent movement offered `공격하시겠습니까(Y/N)?`.
  Confirming `y` was followed by `공주군은 전군 퇴각했습니다` and then
  `조조군의 승리입니다`. The remaining friendly total was 4,813.
  An enemy total of zero after retreat does not prove every enemy was killed.
- After the captured Kong Zhou was released, November commands still
  placed Xiahou Dun in Puyang. His information showed 2,580 soldiers,
  training 79 and morale 55. A field victory did not establish city 20
  ownership; verify the destination's command screen separately.
- A second expedition from Puyang to city 20 selected Xiahou Dun's 2,580
  and Cao Hong's 2,000 infantry, gold 500 and food 20,000. Xiahou Yuan's
  668 remained in Puyang. Declining another city's joint expedition opened
  city 20's deployment with defender strength 0. Place the officers and
  answer the food-carrier prompt even when the defending army is empty.
- The game reported the capture of the retreating Li Gui and then victory.
  His disposition offered recruitment, release or execution; selecting
  recruitment with `1`, Enter returned to city commands. The resulting
  city 20 command named ruler Cao Cao and governor Xiahou Dun. That screen
  proves occupation; the recruitment choice alone does not prove Li Gui
  accepted service.

Keep checkpoints at the field victory, the returned origin-city commands
and the destination-city commands. These observations establish those local
play transitions, not a completed winning campaign.

## Defending a captured city with reinforcements

In November 189, after capturing city 20, ending its commands was followed by
Dong Zhuo's attack from city 7 against Puyang, city 9. The notice showed enemy
strength 14,804. Requesting help with `y`, then city `10`, Enter advanced to a
second-city selector. City 20 did not advance that selector; empty Enter ended
it. A message then reported the request messenger at Chenliu.

The Chenliu list selected Cao Cao 1,800, Cao Ang 1,900, Li Dian 1,900 and Cao
Ren 1,565. Each officer selection was followed by infantry `1`, Enter. Empty
Enter ended selection; `y` confirmed dispatch. This was a request and dispatch,
not arrival. Puyang's own defender Xiahou Yuan had only 668 soldiers.

The city defense opened placement. At its observed cursor, three separate north
`8` presses followed by `0` placed Xiahou Yuan inside the city; an earlier `0`
on a different cell did not complete placement. Use permitted cells and inspect
the resulting command prompt rather than applying this sequence to every map.
On day 2 morning, `조조군이 도착했습니다` appeared; after Space, own strength
was 7,833, an increase of exactly 7,165. Subsequent named commands and movement
for all four reinforcements proved controllable arrival.

A preserved failed branch displayed `조조군이 전멸했습니다` while aggregate
friendly strength still showed 6,914. An alternate checkpoint replay preserved
7,833 through day 5 morning before retreat destinations were requested. The
reason for the retreat transition was not established; neither waiting nor
moving inside the city was proved to guarantee successful defense.

Each of Xiahou Yuan, Cao Ang, Cao Cao, Li Dian and Cao Ren then selected the
listed city 10 with separate `1`, `0`, Enter inputs. The defeat message appeared.
December Chenliu's own roster confirmed all five arrivals. Xiahou Yuan's
individual panel showed soldiers 668, training 100, morale 66 and loyalty 100.
Officer arrival does not preserve Puyang, and other individual troop totals
were not separately inspected. Keep failed and restored branches distinguishable.
