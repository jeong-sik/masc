---
name: sangokushi-3
description: "삼국지 III (Koei 1993, Korean) on the shared DOS machine: boot with KOEI.COM, the copy-protection code, the numbered prompts from main menu to the first ruler's turn, a 2-player hotseat, and ending a month. Apply a fact only when the visible prompt matches it."
---

# 삼국지 III

Everything below is an observation from real runs on the DOS lane, not a rule
of the game. Apply a step only when the screen shows the prompt it names, and
read the screen (PNG artifact) after every decision. The general DOS lane
rules — controller, passing, saves — are in the `dos-play` Skill.

## Boot

`masc_dos_load` with `program: samguk3`, `boot: KOEI.COM`. KOEI.COM runs the
opening (OPEN.EXE) and then the game (MAIN.EXE). The KOEI logo waits for a
key; `enter` skips the opening.

## Copy protection

A white box: `CODE:` / `INPUT CODE [孔李李]`, three red hanja. The code for
`[孔李李]` was `10183`: `masc_dos_type` `10183`, then `enter`. If the box
shows different hanja, the code is not known here — ask the operator rather
than guessing, since a wrong code ends the program.

## From the title to the first turn

Every prompt ends in `(range)?`; type the number, then `enter`.

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

## Hotseat

With two human players (유비 and 조조 in scenario 1) the game asked 조조 first
in 189년 봄 1월, and after 조조 ended the month the next settled screen asked
유비 — the AI rulers' turns ran inside that one call. When the prompt names a
ruler played by another Keeper, pass the controller to them (`dos-play`).
