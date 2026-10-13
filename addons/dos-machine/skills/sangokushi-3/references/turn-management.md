# sangokushi-3 — Turn management

Part of the `sangokushi-3` Skill. Same caveat as the main file: these are observations
from a real campaign state; apply them only when the visible prompt matches.

## Recruit additional troops, then assign final officer totals

At Cao Cao's December 189 city-10 Chenliu command, military `1`, Enter,
recruit `6`, Enter opened a list of officers and their charm. Selecting
Cao Cao at the displayed index `1`, Enter marked the selection; an empty
Enter advanced to `몇백 명 모집하겠습니까(1-54)?`.
The quantity is in hundreds: `54`, Enter produced `남은 병사수:5400`.
Use the range displayed for the current city; 54 was this turn's maximum.

The next list asks `누구를 변경하겠습니까?`. It allocates the new troops
among officers, rather than asking for another recruitment order. Xiahou
Yuan had 668 troops at allocation index `4`. Selecting `4`, Enter opened
`하후연의 병사를 몇 명으로 하겠습니까(0-6068)?`: this number is his
**final troop total**, including the 668 he already held. Entering `6068`,
Enter raised his allocation to 6068 and reduced remaining troops to zero.
An empty Enter then opened `좋겠습니까(Y/N)?`; `y` completed the order.
Reopening his own officer information confirmed 6068 troops, training 59
and morale 57, compared with 668 troops, training 100 and morale 66 before
recruitment. Read each live list: the officer index in allocation differed
from his index `5` in own information.

A subsequent military training order selected Xiahou Yuan at its displayed
index `4`, Enter, empty Enter, `y`. His information showed
`훈련에 종사(1개월)` while training remained 59. After ending both Chenliu
and city-20 Cho commands, January 190's Chenliu report showed
`훈련: 훈련도 상승`. His information then confirmed 6068 troops, training
68 and morale 61, with no pending training line. These are this recruit and
training sequence's measured values, not fixed recruitment penalties or
training gains. Resource costs and a full campaign win are not established
by this sequence.

## Training orders complete at month progression

At Cao Cao's May 189 city-9 Puyang command, military `1`, Enter,
training `7`, Enter opened a list with Xiahou Dun, Xiahou Yuan and Cao Hong
all at training 60. Selecting Xiahou Dun `1`, Enter retained the list.
An empty Enter then opened `훈련시키겠습니까(Y/N)?`; `y` returned to
commands. The military training option was subsequently red that month.

Own information `4`, Enter → `2`, Enter → `1`, Enter opened the officer
list. Choosing the current Xiahou Dun index `1`, Enter showed
`훈련에 종사(1개월)`, training 60, morale 48 and soldiers 2181. The order
had been assigned; the training increase had not happened yet.

After ending Puyang's May commands and Chenliu's June commands with
`0`, Enter, `y` at each named command prompt, a Puyang report displayed
`훈련: 훈련도 상승`. Space continued to Puyang's June command.
Reopening the same officer information showed training 79, morale 57 and
soldiers 2181, with no pending training assignment line. This proves that
specific one-month order and observed 60 → 79 result, not a universal gain,
a rule for every officer, or a winning campaign.

A February 190 Chenliu order selected six officers. After an intervening
city-20 defense and retreat, March Chenliu's report still displayed
`훈련: 훈련도 상승`. Individual information confirmed Cao Cao 53 → 91,
Xiahou Yuan 68 → 100, and Cao Ang, Li Dian, Cao Ren and Chen Gong 60 → 98.
Their troops remained 2,500, 1,637, 1,900, 589, 939 and 1,500 respectively.
The March roster indices differed from the selection list: identify officers
by their visible names before comparing their results. This verifies those
six completed orders despite the intervening battle, not a fixed training gain.

## Cancel an undersupplied expedition and buy food

At March 190 Chenliu, a prepared expedition of 10,260 infantry carried
500 gold and 14,000 food. The advisor warned `군량이 부족한 것은...` at
`쳐들어가겠습니까(Y/N)?`. Answering `n` returned to city commands with the
original gold 963, food 18,380 and troops 12,760 restored. Preparation had
not launched the expedition; do not count the resource-entry screen as dispatch.

At that city's command, merchant `7`, Enter → `2`, Enter selected
`군량매입`. Choose an available officer from the live charm list; Yu Yuan
was index `4` in this replay. `4`, Enter opened
`군량을 얼마나 사겠습니까(64-61632)?`. Entering `20000`, Enter returned
to commands with food 38,380, gold 651 and unchanged troops 12,760.
This confirms a purchase of 20,000 food for 312 gold in this state, not a
universal exchange rate or merchant availability. Preserve the resupplied
state before preparing another expedition, and inspect the next resource
and advisor prompts rather than restoring the earlier undersupplied preparation.
