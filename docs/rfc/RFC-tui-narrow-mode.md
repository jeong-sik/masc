---
rfc: "tui-narrow-mode"
title: "TUI 좁은 모드 — 표의 바닥 폭은 표가 말하고, 그 아래에서는 자르지 않고 쌓는다"
status: Draft
created: 2026-10-06
updated: 2026-10-06
author: jazz-developer
supersedes: []
superseded_by: null
related: ["tui-operator-workbench"]
implementation_prs: []
---

# RFC: TUI 좁은 모드 (tui-narrow-mode)

## 0. 요약

작업대 RFC §5.4(#38988)가 표마다 빼는 순서(`drop_order`)와 늘어나는 열(`flex`)을 정한 뒤에도
한 가지가 정해지지 않았다. 빼는 순서가 모두 소진됐는데 행이 pane 보다 넓으면 어떻게 하는가.
`Masc_tui_table.fit` 의 계약은 그 지점을 프레임의 절단에 맡긴다 — 어떤 열이 없어졌는지
아무도 정하지 않은 채 오른쪽 끝이 잘린다(task-2025, #40753 리뷰 스레드에서 종결된 항목).

이 RFC 가 정하는 것은 세 가지다.

1. **각 표의 바닥 폭은 표가 스스로 말한다.** 빼는 순서가 소진된 뒤 남는 필수 행 —
   늘어나는 열은 자기 바닥에서 — 를 `Masc_tui_table.floor` 가 `fit` 과 같은 잴법으로 잰다.
   화면은 이 수를 읽어 쓰고, 폭을 second number 로 복사해 두지 않는다(§2).
2. **18개 표면의 바닥 폭 장부.** 착수 전 요구된 전수 조사의 답이다(§3). 소유자 없던
   숫자들이 각자 얼마인지, 74칸에서 실제로 어느 표가 위험한지를 말한다.
3. **바닥 아래에서는 자르지 않고 쌓는다.** Models pane 이 이미 그렇게 한다(task-2018,
   #41213): 필수 읽기를 행으로 내리고, `wrap_words` 로 pane 안에 맞추고, 수치는 접지
   않는다. 나머지 표의 쌓기는 이 규칙을 따라 표별로 옮겨 간다(§4, 이 RFC 가 맡지 않는
   부분은 §5).

## 1. 배경 — 계약이 오늘 남기는 구멍

`Masc_tui_table.fit` 의 계약(masc_tui_table.mli): 빼는 순서의 다음 열이 아직 보이면
없애고, 이름 없는 열과 `flex` 는 안 없앤다. 전부 없앴는데도 안 맞으면 "`flex` 는 자기
바닥에 머물고 행은 공간보다 넓어진다. 프레임의 절단이 그것을 담당한다" — 그리고 그
절단이 무엇을 없애는지는 **표가 아니라 터미널이 정한다**. 74칸 미만 pane 에서 마지막
열(자주 시계다)이 사라지는 것이 그 모양이다.

작업대 RFC §5.4는 표가 무엇을 먼저 내려놓는지는 정했지만, 내려놓을 것이 없을 때 무엇을
지키는지는 정하지 않았다. 그 경계선의 숫자 — 표별 바닥 폭 — 도 어디에도 적히지 않아
좁은 모드를 만들려는 화면마다 폭을 다시 세거나 짐작해야 했다.

## 2. 원칙

1. **바닥은 계산된다, 복사되지 않는다.** `Masc_tui_table.floor ~width ~flex ~drop_order
   columns` 는 `fit` 이 마지막으로 쥐는 필수 행의 폭(간격 포함)을 같은 `width` 설명에서
   잰다. 바닥 위에서 `fit` 은 행이 맞을 때까지 빼다 멈춘다. 바닥 아래에서 `fit` 은 필수
   행에 도달해도 맞지 않는다 — 정확히 그 한 칸에서 두 행동이 갈린다
   (`test_tui_table.ml` "the floor is where the drops stop").
2. **바닥 이상이면 열 접기로 수용한다.** 이 구간은 `fit` 의 영토다. 화면이 여기서
   쌓거나 접어서는 안 된다 — 계약이 이미 최선의 열 집합을 고른다.
3. **바닥 미만이면 쌓는다.** 화면은 자기 표의 공개된 바닥 상수(또는 함수)와 pane 폭을
   비교해 쌓은 레이아웃을 고른다. 쌓기의 규칙은 Models pane 이 정한 것을 따른다:
   (a) 필수 읽기가 전부 보인다 — 절단이 지우는 것이 없다; (b) 줄은 `wrap_words` 로
   pane 안에 맞는다; (c) 수치는 절단해 다른 수로 읽히게 하지 않는다.
4. **새 표는 장부에 한 줄을 더한다.** `drop_order`·`flex`·바닥을 선언하고
   `test_the_narrow_floors_the_lists_are_read_to` 에 같은 한 줄을 더한다. 장부에 없는
   표는 리뷰에서 돌려 보낸다.

## 3. 장부 — 18개 표면의 바닥 폭 (전수 조사, 2026-10-06 main 기준)

`fit` 을 쓰는 표 13개와 자기 배분을 쓰는 표 5개. 바닥은 소스 산술로 재었다(검산 위치를
적었다). 도구 목록(`masc_tui_tool_table`)과 Fleet 한 줄(`masc_tui_fleet_line`)은 열이
아니라 세로 쌍(이름 행, 값 행)이라 절단이 없고 장부 밖이다.

| # | 표(화면) | 소스 | 필수 행(빼는 순서 소진 뒤) | 바닥(칸) | 바닥 아래 현재 동작 |
|---|---|---|---|---|---|
| 1 | Clients | render.ml:4834 | STATUS·LAST SEEN·NAME(1까지 수축) | 21 | frame cut |
| 2 | Workspace Activity | render.ml:8003 | DATE·KEEPER·RESULT·FILE | 51 | frame cut |
| 3 | Connectors | render.ml:9173 | CONNECTOR·REACHABLE·STATUS·CHANNEL | 52 | frame cut |
| 4 | Runtime(모드별) | render.ml:9407 | LANE 모드: LANE·CANDIDATE·ROUTE(54) / all 모드: RUNTIME·ROUTE(43) | 54·43 | frame cut |
| 5 | Repositories | render_schedule:417 | NAME·STATUS·PATH | 37 | frame cut |
| 6 | System log | render_schedule:515 | TIME·LEVEL·MESSAGE | 29 | frame cut |
| 7 | Schedules | render_schedule:730 | STATUS·DUE·TARGET·RECURRENCE | 33 | frame cut |
| 8 | Keeper Automation | render.ml:6140 | MARK·STATUS·TRIGGERED·RECEIVED·WHAT | 62¹ | frame cut |
| 9 | Lane runs | render_schedule:1080 | SUBJECT·STATUS·SLOT | 53 | frame cut |
| 10 | Changes | render_schedule:1184 | FILE·SUMMARY | 51 | frame cut |
| 11 | Verdicts (Harness) | render_schedule:1494 | TASK·VERDICT·REASON | 37 | frame cut |
| 12 | Planning goals | render_schedule:1620 | PHASE·PRIORITY·TITLE | 38 | frame cut |
| 13 | Board | render_schedule:1779 | MARK·TITLE·AGE | 39 | frame cut |
| 14 | Models pane | render.ml:12288 | 전부(provider·model·effort·temp·tokens) | 40 | **쌓음** (#41213) |
| 15 | Memory 목록 | render_schedule:236 | ST·KEEPER·FACTS·SIZE | 45 | revision→source 끔, 그 뒤 cut |
| 16 | Keeper roster | render_schedule:154 | MARK·STATUS·NAME·LAST TURN | 48 | flags→runtime→task 끔, 그 뒤 cut |
| 17 | Fusion runs | render_schedule:1300 | STARTED·AGE·STATE(+KEEPER 6·RUN 3) | 56 | preset 끔, 그 뒤 cut |
| 18 | Task Review | render_schedule:598 | TASK·EVIDENCE·TITLE + SUBMITTED BY | 58² | frame cut |

¹ Automation 의 상태·시계 폭은 호출자가 계약 어휘와 스탬프 형식에서 재는 상수라 바닥은
두 인자의 함수다(`kauto_floor_width`). 표의 값은 가장 좁은 정당한 페이지 기준이고,
앞의 2칸 lead 는 바깥에 있다. 검산: `kauto_floor_width ~status_width:7 ~clock_width:16 = 60`.
² submitter 는 페이지에서 재지만 16칸 아래로는 안 내려간다(render.ml:7004). 16 기준.

### 3.1 장부가 말하는 것

74칸 단일 pane 기준(프레임 안쪽 약 69칸)으로 **18개 표면 전부가 바닥 위**다. 즉
"<74칸이면 표가 잘린다"는 인상은 틀렸고, `fit` 의 열 접기가 이미 수용한다. 절단이
실제로 남는 구간은 표마다 다르고, 그 시작점이 위 표의 숫자다 — 실전에서 닿을 곳은
Automation(2칸 lead 포함 62 미만), Task Review(submitter가 긴 페이지), Memory(revision
과 source를 다 켜면 75), Models(40 미만), 그리고 40칸 안팎까지 내려가는 초협폭이다.
좁은 모드의 문은 이 숫자들에서 열린다: 어디까지는 접고, 어디부터는 쌓는다.

## 4. 쌓기 — 바닥 아래의 계약

Models pane 이 착지시킨 방식(#41213, `Masc_tui_model_runtime_table.stacked_lines`)이
규범이다.

- 필수 읽기는 전부 보인다. 라벨과 값을 한 행에 붙여 내리고(`"max-tokens 16384"`),
  없는 값은 `-` 로 말한다.
- 행은 `wrap_words ~max_cells:pane` 으로 pane 안에 맞는다. pane 은 표에 준 폭이 아니라
  실제 그릴 폭이다(#28905 — 이 둘이 다르면 마지막 열이 자기 행으로 내려앉았다).
- 수치는 절단하지 않는다. 잘린 `1638` 은 16384 의 다른 수로 읽힌다. 이름은 중간 접기가
  허용된다 — 잘린 이름은 여전히 같은 행을 가리킨다.
- 전환 판정은 표가 공개한 바닥으로 한다. 화면이 자기 상수를 만들어 비교하지 않는다.

나머지 17개 표면의 쌓기 구현은 표별로 옮겨 가되, 이 RFC 의 규칙(§2)과 장부(§3)가
판정 기준이다. 어느 표부터 쌓을지는 바닥 아래가 실측으로 닿는 빈도(#3.1의 우선순위)로
정한다.

## 5. 이 RFC 가 맡지 않는 것

- 쌓은 레이아웃의 키 이동(커서가 행을 걷는 방법)은 표별 후속 PR 이 각자 정한다. Models 의
  "cursor walks bindings, not lines" 가 precedents 다.
- 창(pane 분할) 임계값 — Activity 패널의 102칸, roster 의 110칸 등 — 는 작업대 RFC
  §5.9·D13 이 정한 것이고 이 RFC 가 바꾸지 않는다.
- `Masc_tui_table.floor` 의 도입(8ad2f7b2a)과 장부 테스트(9b93d7596, 1d9d4ba2d)는 이미
  착지한 것이고, 이 RFC 는 그 위의 정책 문서다.

## 6. 확인

- 장부: `test_the_narrow_floors_the_lists_are_read_to`(test_tui_render_schedule.ml) —
  schedule 렌더러 9개 목록의 바닥을 손으로 합산한 값과 대조한다. 열이 넓어지거나
  새로 생기면 이 테스트가 먼저 빨간다.
- 경계: `test_floor_is_where_the_drops_stop`(test_tui_table.ml) — 바닥에서 `fit` 의
  유지 집합이 정확히 필수 행임을, 위아래 한 칸씩 못박는다.
- 실기: `test_tui_narrow70_pty.py`(test/) — 70칸 PTY 에서 Dashboard·Keepers·Board 를
  그리고 그려진 모든 행이 pane 셀 폭 안에 드는지 단정하는 영수증 시나리오. dune
  `runtest-test_tui_narrow70_pty` 로 돈다.
