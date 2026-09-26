---
rfc: "tui-operator-workbench"
title: "TUI 작업대 — 모든 화면에 같은 클릭·스크롤·복사·추이 부품을 쓴다"
status: Draft
created: 2026-09-26
updated: 2026-09-26
author: dancer + claude
supersedes: []
superseded_by: null
related: ["tui-measured-operator-home", "tui-operator-ia", "tui-single-input-decoder", "0459", "0462", "tui-chat-boundary-continuity"]
implementation_prs: []
---

# RFC: TUI 작업대 (tui-operator-workbench)

## 0. 요약

운영자가 2026-09-26 16:05–16:07(KST)에 TUI 화면 35장을 찍어 전체 흐름을 다시 봤다.
최상위 메뉴는 이미 `RFC-tui-measured-operator-home`(Accepted, 09-25, #38801 에 있음)이 7곳으로 정했다.
Dashboard, Work, Keepers, Usage, Board, Workspace, System 이다. 이 RFC 는 그 결정을 바꾸지 않는다.
그 RFC 와 다르게 정하는 것은 §10 의 결정 항목으로 따로 적었다.

이 RFC 가 정하는 것은 세 가지다.

1. **모든 화면이 같은 부품을 쓴다.** 클릭, 휠, 몇째 줄을 보는지 표시(`rows a–b/n`), 원문 복사,
   접기·펼치기, 열 폭 배분이다. 지금은 화면마다 따로 만들어서 같은 결함이 화면을 옮겨 다닌다(§2).
2. **7곳 안의 배치를 정한다.** 지금 있는 23개 surface, Keeper 상세 9칸, Config 7칸이 어디로 가는지,
   무엇을 합치고 지우는지 한 표로 적는다(§4).
3. **실시간과 추이를 한 모양으로 보여 준다.** 지금 도는 턴, 계정별 사용량, 시간·일·주 추이다(§6).

구현은 스택 PR 로 나눈다(§8). 부품을 먼저 만들고, 화면은 그다음에 옮긴다.

## 1. 화면에서 본 것

스크린샷은 운영자 장비에서 약 200×56 셀로 찍었다. 공개 저장소라 이미지 파일은 올리지 않는다.
아래는 관찰을 옮긴 것이다. 코드로 확인한 것은 위치를 적었다. 줄 번호는 `32e09f3db0` 기준이다.

### 1.1 위계가 없다

- 최상위 10칸이 같은 무게로 나란히 있다. Config 는 하위 7칸이 있고,
  Runtime·Resources·Tools 는 탭에 없어 키(`9`, `s`, `t`)로만 간다.
- Keeper 상세는 9칸이다. 자주 쓰는 대화·호출·로그는 칸에 없고 키(Enter, `t`, `o`)로만 간다.
  드물게 쓰는 칸이 Info 와 같은 무게로 있다.
  - Identity: 서비스 89개가 전부 `not attached` 로 한 화면을 채운다.
  - Automation: 78행 중 1행만 예약 중이고 75행이 닫힌 예약이다.
  - Runs: 이 Keeper 의 Fusion 실행 목록인데 `No retained Fusion runs` 한 줄이다.
- Task Review 103행의 VERDICT 열이 전부 `cancel` 이다. 이 열은 이 행이 기다리는 판정의 종류(complete/cancel)다
  (`bin/masc_tui_render_schedule.ml:693`). 그런데 머리글이 VERDICT 라서 이미 내린 판정으로 읽힌다.

### 1.2 같은 것을 여러 곳에서 다르게 말한다

| 사실 | 보이는 곳과 표기 |
|---|---|
| Keeper 상태 | 오른쪽 Activity 패널 `open`/`done`/`no events` · Keepers `failing`/`offline`, Mode `A M` · Overview Team `need you`/`working`/`idle`/`no phase` · Memory `+`/`!` |
| 전체 건강 | Overview `Health: bad` · Keepers `fleet ok` 옆에 `8 failing` |
| 운영자가 할 일 | 하단 `Awaiting you·104` · 탭 `Planning·103` · Overview `Approvals: 0` · Keepers `awaiting verdict 103` |
| 비용 | Keeper Info `Total Cost: $0.0000`, 같은 화면 24h 칸 `Cost: not priced by the provider` |
| Fusion 실행 | Fusion 탭과 Keeper Runs 칸. 상태 표기 세 벌(`render_prim.ml:2393`, `render.ml:8107`, `render.ml:10672`) |
| 쿼터 소진 | 표기 세 벌(`render_prim.ml:2829`, `types.ml:10054`, `overview_providers.ml:200`) |

두 줄은 원인이 화면이 아니라 데이터 쪽에 있다.

- **`fleet ok`.** TUI 가 읽는 `keeper_fleet_safety` 의 status 는 종합 판정이다
  (`lib/server/server_routes_http_runtime_fleet_scan.ml:1366`). 실행 가능한 Keeper 가 없거나
  대상 Keeper 가 전부 운영자 대기이면 `blocked` 다. 턴 설정 오류, 공식 클라이언트 복구 필요,
  처리 여력 부족, 담당 Keeper 없는 Task, backlog 읽기 저하 중 하나면 `degraded` 다.
  제공자 한도로 턴이 실패하는 Keeper 는 이 판정에 들어가지 않는다. 그래서 8명이 실패 중이어도 `ok` 다.
  화면은 이 이유를 보여 주지 않고, 색은 문자열 비교로 정한다(`bin/masc_tui_render.ml:5188`).
- **비용 0.** Keeper 의 누적 비용은 `float` 이고(`Keeper_meta_contract.usage_metrics.total_cost_usd`),
  가격이 없는 턴도 0 을 더한다(`keeper_owner_reducer.ml` 의 `add_usage`). 모르는 값과 0 이 섞인다.

### 1.3 마우스와 스크롤

- 클릭이 되는 곳은 오른쪽 Activity 패널, Lanes 목록, 채팅의 접힌 Gate 행, Browser Lane 화면뿐이다.
  탭, 제목 줄의 하위 칸, 목록 행, footer 키는 눌리지 않는다.
- Lanes 목록의 클릭 위치는 제목·구분선 7행을 손으로 센 값으로 계산한다(`bin/masc_tui_types.ml:9021`).
- 휠은 `wheel-up`/`wheel-down` 이라는 키 이름으로 바뀌어 처리된다(`bin/masc_tui.ml:18255`).
  `j`/`down` 을 받는 처리 37곳 중 휠 키도 받는 곳은 2곳이다.
  그래서 상세 화면이 휠을 받지 않고, 뒤에 가려진 목록의 선택이 움직인다.
  - Memory fact 상세(`:21358`)를 열고 휠을 굴리면 fact 목록의 선택이 움직인다(`:22965`).
  - Activity 증거 상세(`:21385`)를 열고 휠을 굴리면 Activity 목록의 스크롤이 움직인다.
  - 코드로 확인했고, 실측은 아직이다.
- 휠의 뜻은 화면마다 다르다. 채팅은 3행 스크롤, 질문 답하기는 본문 스크롤, 삭제 목록은 상세 스크롤,
  나머지 목록은 선택 1행 이동이다.
- 숫자 바로가기는 `2`(Keepers) 하나뿐이다(`bin/masc_tui_keys.ml:220`). `p`, `v`, `9`, `[`/`]` 는 화면마다 뜻이 다르다.
- footer 는 대부분 화면에서 잘려 `…?` 로 끝난다.
- 원문을 복사할 길이 없다(#39170). 끌어서 복사하면 화면 폭 줄바꿈과 옆 패널 글자가 같이 딸려 온다.
  지금 `y`/`Y` 는 어떤 화면에서는 참조 복사, Approvals 에서는 승인이다.

### 1.4 실시간과 추이

- 기본 2초 폴링에 observer SSE 가 더해진다. 오른쪽 Activity 패널이 호출 수와 새 토큰을 실시간으로 보여 주는 것은 잘 동작한다.
- 추이는 Overview Pulse 스파크라인과 Team 14일 막대 둘뿐이다. 범위를 바꿔 볼 곳이 없다.
- Keeper 비용 API 는 최대 24시간 창 하나를 합계로만 준다(`lib/dashboard/dashboard_http_keeper_feeds.ml:85`).
  24시간 상한은 새로고침마다 공개 경로에서 일 파일을 전부 읽는 비용 때문이다.
- 제공자 사용량은 "서버 시작 이후"만 보인다. #38801 이 scope 별 일 단위 이력을 1·7·14일 창으로 더한다.

### 1.5 소음

- ID 와 경로가 행의 절반을 쓴다. Board ID 열, Lanes RUN ID 열, Channels 의 경로 9줄, Sandbox 경로 5줄이다.
- 설명 없는 한 글자 표식이 있다. `A M`, `D M`, `+`, `!`, `r2 i0`, `Δ +1 -3` 이다.
- Presets 목록은 schema 1 프리셋 7개를 요약까지 그린다. 그런데 상세는
  `HTTP 404: unsupported schema_version 1 (expected 2)` 로 읽지 못한다. 목록과 상세가 다른 규칙으로 읽는다.

## 2. 코드에서 본 것 — 1주 336커밋

2026-09-19부터 09-26까지 `bin/masc_tui*` 를 건드린 커밋이 336개다(+27.1k/−8.1k). 하루 최대 101개(09-23)다.
같은 결함을 화면 하나씩 고친 커밋이 많다. Approvals 한 화면에 PR 9개가 들어갔고,
그중 4개(#38666, #38917, #39172, #39169)가 "못 읽음과 비어 있음을 구분하지 못한다"는 같은 결함이었다.

| 부품 | 지금 몇 벌인가 | 정본 |
|---|---|---|
| 글자 맞추기·자르기·채우기 | 최상위 함수 약 24개 + 지역 함수 약 15개. 두 개는 칸이 아니라 바이트를 센다 | `Message_layout.fit_width` |
| 스크롤 상한 계산 | 정본 옆에 약 46곳. `render.ml` 의 35곳은 정본을 부르지 않는다 | `Masc_tui_scroll` |
| 스크롤·커서 상태 필드 | `mutable *_scroll` 51개, `mutable *_cursor` 45개(`bin/masc_tui_types.ml`) | 없음 |
| 막대·게이지 | 6개 | 없음 |
| "못 읽음" 생성자 | `Masc_tui_fetched` 옆에 `*_unread` 생성자 14개(이번 주 5개 추가) | `Masc_tui_fetched` |
| Keeper 목록을 그리는 곳 | 7곳, 상태 어휘 4벌 | 없음 |
| footer 힌트 | `~hints:"…"` 직접 문자열 14곳이 키 표를 지나친다 | `Masc_tui_keys` |
| 손으로 센 제목·구분선 행 | `rows - 5`, `rows - 6`, `rows - (if editing then 10 else 7)` 등 6곳 | `count_frame_lines` |

**결론.** 화면 하나씩 고치는 PR 은 결함을 다음 화면으로 옮긴다. 부품을 먼저 하나로 모으고,
옛 부품은 같은 스택의 마지막 PR 에서 지운다. 옛 부품을 지우기 전까지는 두 방식이 같이 있으므로,
그동안 컴파일러가 남은 자리를 전부 찾아 주지는 않는다. §9 의 개수 측정으로 남은 자리를 센다.

## 3. 원칙

1. **첫 화면은 두 질문에만 답한다.** "내가 지금 할 일이 있나"와 "잘 돌고 있나"다(measured-home RFC 그대로).
2. **한 개념은 한 곳에서, 한 이름으로 보인다.** 다른 곳에는 요약 한 줄과 그곳으로 가는 링크만 둔다.
3. **모든 목록은 같은 조작을 받는다.** 클릭은 선택이고, 이미 선택한 행을 다시 누르면 연다(Enter 와 같음).
   휠, `rows a–b/n`, `/` 찾기, Home/End, PgUp/PgDn 을 모든 목록이 받는다.
4. **마우스로만 되는 일은 없다.** 클릭은 키보드가 하는 것과 같은 동작을 부른다.
5. **모르는 값은 모른다고 쓴다.** 0 으로도, `?` 로도 그리지 않는다(RFC-0462).
6. **제공자가 말한 것만 보여 준다.** 사용량 숫자로 "곧 소진"이나 "회복됨"을 짐작하지 않는다(#38801 계약).
7. **원문이 먼저다.** 복사는 원문을 보낸다. 링크는 OSC 8 로 건다. 긴 것은 접고 펼친다.
8. **열 폭은 선언된 순서로 나눠 준다.** 열마다 우선순위를 두고, 좁아지면 그 순서로 뺀다(#38988).
9. **문자열로 분기하지 않는다.** 상태, 표식, 색은 variant 에서 나온다.

## 4. 7곳 안의 배치

### 4.1 지금 있는 곳 → 갈 곳

`surface` variant(`bin/masc_tui_types.ml:2838`) 23개와 하위 칸을 전부 적는다.
"합침"은 한 화면의 구역이 된다는 뜻이다. "지움"은 코드와 테스트를 같이 지운다는 뜻이다.
measured-home RFC 와 다른 줄은 결정 항목 번호를 달았다.

| 지금 | 갈 곳 | 처리 |
|---|---|---|
| Overview | Dashboard | #38801 이 바꾼다 |
| Acting(Events), System_logs(Logs) | System › Activity | #38801 그대로 |
| Metrics(telemetry) | Usage › Telemetry | #38801 그대로 |
| Keepers(목록) | Keepers | §4.2 묶음 보기 |
| Keepers 상세 9칸 | Keepers 상세 7칸 | §4.3 |
| Changes | Keepers 상세 변경 칸 | 옮김. Keeper 하나의 파일 변경이다 |
| Memory(Keeper 건강 표, fact 목록) | Keepers 목록의 Memory 열 + Keeper 상세 Memory 칸 | 합침. D3 |
| Lanes(Standalone) + Runtime(Lanes, All runtimes) + Clients | System › Lanes | 한 화면의 구역으로 합침 |
| Approvals, Verification(Task Review) | Work › Awaiting you | 합침. D5 |
| Planning(Goals) | Work › Goals | #38801 그대로 |
| Harness(Task Verdicts) | Work › Verdicts | 옮김. 생성자 `Harness` 를 `Verdicts` 로 바꿈 |
| Fusion | Work › Fusion (Keeper 로 거르기) | 옮김. Keeper Runs 칸은 지움. D6 |
| Schedules | Keeper 상세 Schedule 칸 + Work › Schedules | 옮김. D6 |
| Board | Board | §5 부품만 적용 |
| Repositories, Code | Workspace | 그대로 |
| Config(7칸), Resources, Tools, Connectors | System › Config, Tools, Connectors | #38801 그대로 |
| 오른쪽 Activity 패널(Recent/Changes) | "지금" 패널 | §6.1. D2 |

### 4.2 Keepers 목록 — 상태로 묶어 보기

Claude Code 의 agent view 처럼 상태로 묶어 화면 전체를 쓰는 표로 보여 준다.
세션 수십 개를 옆 패널에 세로로 늘어놓는 모양은 Amp 가 TUI 에서 없앴다(§9 참고 자료).

```
Keepers 24                          needs you 1 · failing 8 · working 4 · idle 10 · offline 1
▾ Needs you (1)
  ● jazz-developer     task-1719  12h30m  질문 1개 대기
▾ Failing (8)                                                     ! 문제만 보기
  ! rondo              glm-5.3-flash  rate limited · 다음 시도 16:06:51   28회 연속
  ! context-reviewer   glm-5.3-flash  rate limited
▾ Working (4)
  ◐ goo-yang-bong      task-1762  8m33s  tool_execute
▸ Idle (10)  ▸ Offline (1)
```

- 상태 어휘는 한 벌이다. 하나의 variant 에서 목록, Activity 패널, Dashboard 요약이 모두 나온다.
- `!` 는 문제 있는 묶음만 보이게 켜고 끈다. k9s 의 `ctrl-z` 와 같은 역할이다.
- `A M` 같은 한 글자 열은 없앤다. 모드와 샌드박스는 상세에 문장으로 적는다.
- fleet 판정은 `ok`/`degraded`/`blocked` variant 와 그 이유(§1.2)를 같이 보여 준다.

### 4.3 Keeper 상세 — 9칸에서 7칸으로

자주 쓰는 것을 앞에 둔다. 대화는 지금 Enter 로만 가는데, 칸으로 올린다.

| 새 칸 | 담는 것 | 지금 어디에 있나 |
|---|---|---|
| 대화 | 대화 기록, 접기·펼치기, diff, 이미지, 원문 복사 | `Keeper_message` 모드 |
| 호출 | 도구 호출과 영수증 | `t` 키의 Calls 모드 |
| 변경 | 파일 diff | Changes surface |
| 상태 | 현재 실패, 문맥 사용량, 24h 사용량, Board attention, Memory·Schedule 요약 | Info |
| Memory | 이 Keeper 의 fact 목록과 상세, Librarian 상태 | Memory surface |
| Schedule | 예약 중인 것 먼저. 닫힌 것은 접힌 한 줄(`닫힌 75개 · 성공 11 · 취소 64`) | Automation |
| 설정 | Settings, Sandbox, Secrets, GitHub, Identity, Channels 를 섹션으로. 연결된 것 먼저, 연결 안 된 것은 접힌 한 줄(`서비스 89개 중 0개 연결`) | 6칸 |

로그(`o`)는 상태 칸과 설정 칸에서 키로 연다.

### 4.4 Work — Awaiting you 한 목록 (D5)

지금 `Awaiting you`, `Planning·N`, `Approvals`, `awaiting verdict` 가 서로 다른 숫자를 말한다.
Work 의 첫 칸을 **Awaiting you** 로 하고, 운영자 판단을 기다리는 것을 한 목록에 모은다.
지금 Approvals 가 한 목록에 섞는 세 종류(`Approval_authority` 의 `Operator_row`, `Keeper_tool_row`, `Gate_row`)에
Task 완료 요청과 Goal 확인을 더한다. Task 취소는 RFC-0417 §4.1과 constitution의
Task 계약대로 권한 있는 호출자가 사유와 함께 즉시 수행한다. 취소를 이 대기 목록에 넣지 않는다.

```ocaml
type awaiting =
  | Operator_approval of ...           (* 지금 Approvals 의 세 행 종류 그대로 *)
  | Keeper_tool_hold of ...
  | Gate_pending of Tui_decode.gate_pending
  | Task_completion of { task_id : string }
  | Goal_confirmation of { goal_id : string }
```

- 하단 `Awaiting you·N`, 탭 배지, Dashboard 숫자는 모두 이 목록의 길이다.
- Task 완료 요청은 완료 판정을 기다리는 행으로 표시한다. §1.1의 `complete`/`cancel` 관측은
  당시 화면 기록이며 새 목록의 요청 종류가 아니다. 취소는 완료된 전이 기록에서 확인한다.
- 판정 키는 한 쌍으로 통일한다. 지금은 같은 판정을 Approve·confirm·decide·Allow 네 이름으로 부른다(#35885).

## 5. 부품 — 모든 화면이 같이 쓰는 것

### 5.1 누를 수 있는 곳 기록 (`Masc_tui_hit`)

렌더러는 위치가 아니라 문자열을 만든다. 문자열은 여러 번 이어 붙여지고, 잘리고, 가로로 밀린다.
그래서 "이 글자가 화면 몇 열에 있나"를 렌더 중에 넘겨주려면 그리는 자리 전부를 고쳐야 한다.
Bubble Tea 의 bubblezone 이 같은 문제를 푸는 방식을 쓴다.

1. 누를 수 있는 글자를 폭 0 인 표식 두 개로 감싼다. 표식은 끝 바이트가 `m` 인 CSI 다
   (`ESC [ = 1 ; n m` 로 열고 `ESC [ = 2 m` 로 닫는다). 이 저장소의 폭 계산(`display_width`),
   자르기(`fit_width`), SGR 지우기(`strip_sgr`), 테스트의 `CSI_RE` 가 모두 이것을 폭 0 스타일로 다룬다.
   그래서 기존 함수를 고치지 않아도 표식이 글자와 같이 움직인다.
2. 프레임의 줄이 다 합쳐진 뒤 `render` 가 줄마다 표식의 실제 열을 재고, 표식을 지우고,
   바뀌지 않는 클릭 위치 표를 프레임과 함께 돌려준다. 오른쪽 패널, 오버레이, 잘림을 다 거친 최종 화면에서 재므로
   손으로 세는 값이 없다.
3. 메인 루프는 터미널이 그 프레임을 실제로 받았을 때(`Frame_presenter.Presented`)만 이 표를 바꿔 넣는다.
   화면에 없는 프레임의 표로는 클릭을 해석하지 않는다. `presented_approval` 과 같은 규칙이다.

```ocaml
type 'target registry                     (* 한 번의 render 동안 표식 번호 → 대상 *)
val registry : unit -> 'target registry
val reset : 'target registry -> unit
val mark : 'target registry -> 'target -> string -> string

type 'target zones                        (* 한 프레임의 클릭 위치 표. 바뀌지 않는다 *)
val no_zones : 'target zones
val extract : 'target registry -> string list -> string list * 'target zones
val target_at : 'target zones -> row:int -> column:int -> 'target option
```

- 표식은 겹치지 않는다. 열린 표식 안에서 새 표식이 열리면 앞의 것이 그 자리에서 닫힌다.
  잘려서 닫는 표식이 없어진 영역은 그 줄 끝까지로 본다.
- 대상은 닫힌 variant 다. 탭(`surface`), 숨은 칸 표시(`‹2`, `3›`), Keeper 상세 칸, Config 칸이 먼저 들어간다.
  목록 행은 번호가 아니라 ID 로 가리킨다(Keeper 이름, task id, post id). 새로고침으로 순서가 바뀌어도
  누른 행이 바뀌지 않게 하려는 것이다. 오른쪽 패널의 `Target_keeper of string` 과 같은 방식이다.
- 이미 선택한 행을 다시 누르면 연다. 시간으로 재는 더블클릭은 쓰지 않는다.
  #39223 의 마우스 이벤트에는 시각이 없고, 시간 상수는 테스트를 시간에 기대게 만든다.
- footer 힌트는 지금 표시용 글자(`Left / Esc`)로만 있어서, 누른 글자를 키 이름으로 되돌리려면 문자열 해석이 필요하다.
  그래서 footer 클릭은 타입 있는 키 표(#38987) 뒤에 한다.
- 입력 바이트 해석은 #39223(`Masc_tui_input_decoder`)이 맡는다. 이 모듈은 거기서 나온
  `Mouse_left_press`, `Mouse_wheel` 을 해석할 때 위치 표만 제공한다.
- Lanes 목록의 손으로 센 7행(`lanes_overview_hit`)은 이 표로 옮긴 뒤 지운다.

### 5.2 스크롤 위치 하나 (`Masc_tui_viewport`)

스크롤·커서 상태 필드 96개를, 스크롤되는 영역마다 값 하나로 바꾼다.

```ocaml
type anchor = Top of int | Bottom          (* 끝으로 가기는 Bottom. max_int 를 쓰지 않는다 *)
type 'id t = private {
  anchor : anchor;
  selected : 'id option;                   (* 선택한 행의 ID. 읽기 전용 문서는 None *)
  follow : follow;
}
and follow = Following | Paused of { unseen : int }
```

- 영역은 닫힌 variant 다. 상세 영역은 무엇을 여는지를 담는다(`Fact_detail of memory_id` 처럼).
  다른 fact 를 열면 새 영역이라 처음부터 보인다. 지금 열 때 0 으로 되돌리는 동작과 같다.
- 목록 키(j/k, PgUp/PgDn, Home/End, g/G)는 한 함수가 영역에 적용한다. 화면별 `j`/`k` 처리는 지운다.
- **휠 규칙(D8).** 포인터 아래 영역이 목록이면 선택을 3행 옮긴다. 읽기 화면(채팅, 상세, diff)이면 3행 스크롤한다.
  선택한 행이 늘 화면에 남는다는 지금의 렌더 규칙(`render_memory.ml:1054`, `render.ml:16255`)을 지킨다.
  채팅의 3행과 맞춘 값이다. 1행 이동을 기대하는 테스트 두 개를 고친다
  (`test/test_tui_keyboard_input.py` 의 `wheel_scrolls_and_clicks_do_not`, `test/test_tui_pick_list.ml:126`).
- 따라가기: Activity, Board, Lanes 실행 목록, 채팅처럼 자라는 목록은 맨 아래에 있을 때만 따라간다.
  위로 올리면 멈추고 `↓ 새 항목 3` 을 보여 준다. 누르면 맨 아래로 간다.
- 마지막 PR 에서 `Masc_tui_scroll` 의 자유 함수와 `*_scroll`/`*_cursor` 필드를 지운다.

### 5.3 키 표 (#38987)

footer, 도움말, 키 처리가 하나의 타입 있는 키 표를 본다. 이 RFC 는 에픽 #38987 의 범위를 그대로 따른다.
더 정하는 것:

- 최상위 7곳으로 바로 가는 키(D1). 지금은 맨 숫자 `2` 하나가 있다.
- `:` 팔레트가 인자를 받는다. `:keeper rondo`, `:task 1738`, `:go System/Config/params` 이다.
- footer 는 한 줄이다. 들어가지 않는 키는 `?` 시트에만 있다. `…?` 표시는 그대로 둔다.

### 5.4 열 폭 (#38988)

`Table.cell` 에 우선순위와 최소 폭을 더한다. 좁아지면 우선순위가 낮은 열부터 뺀다.
손으로 센 폭 상수(최상위 156개, 그중 74개가 `render_schedule.ml`)는 이 방식으로 옮긴다.
ID 열은 기본 우선순위를 가장 낮게 둔다. ID 는 복사 키로 가져간다(§5.6).

### 5.5 읽기 상태 하나 (`Masc_tui_fetched`)

`Approval_unread`, `Board_list_unread`, `Goals_unread`, `Lane_list_unread`, `Local_workspace_unread`,
`Overview_pulls_unread`, `Overview_spend_unread`, `Page_unread`, `Providers_unread`, `Quota_unread`,
`Rows_unread`, `Spend_rows_unread`, `Spend_unread`, `Workspace_identity_unread` 14개를
`Masc_tui_fetched.t` 하나로 바꾼다. #39209 가 여기에 `Stale`(이전 값 + 실패)을 넣는다.
화면은 네 상태를 같은 모양으로 그린다: 읽는 중, 값, 값 + `오래됨 3m · 새로고침 실패`, 못 읽음 + 이유.

### 5.6 복사와 링크 (D7)

- 복사 키 하나가 선택한 것의 **원문**을 OSC 52 로 보낸다. 메시지 Markdown, fact 문장, 글 본문, 로그 한 줄, diff 다.
- 다른 키 하나가 ID 나 링크를 보낸다.
- 보낸 뒤 상태 줄에 `OSC 52 로 보냄 · 1,204자` 를 남긴다. OSC 52 가 닿았는지는 터미널이 알려 주지 않으므로 "보냈다"고만 쓴다.
- 복사 대상은 variant 하나로 모은다.

  ```ocaml
  type copyable =
    | Message of { keeper : string; source : string }
    | Fact of { memory_id : string; claim : string }
    | Post of { post_id : string; body : string }
    | Log_line of string
    | Diff of { path : string; unified : string }
    | Identity of { label : string; value : string }
  ```

- URL, PR 번호, 로컬 파일 경로는 OSC 8 로 건다. 지원하지 않는 터미널은 글자만 보인다.
- 마우스를 터미널에 돌려주는 `Ctrl-T` 는 그대로 둔다. 도움말에 Shift/Option 을 누른 채 끌어도 선택된다고 적는다.

### 5.7 접기·펼치기와 넓게 보기

- `▸`/`▾` 는 누를 수 있는 대상이다. 클릭, Enter, Space 가 같다.
- 채팅의 추론(Ctrl-R), 도구 상세(Ctrl-D), 턴 접기(Ctrl-S)는 키를 그대로 두고, 같은 접기 상태를 클릭으로도 바꾼다.
- `z` 는 선택한 영역을 화면 전체로 넓힌다. Board 의 `z:wide` 를 모든 상세로 넓힌 것이다.

### 5.8 막대 하나

막대·게이지 6벌(`ansi.ml:747`, `chart.ml:135`, `context_bars.ml:137/143/162`,
`overview_providers.ml:43`, `overview_goals.ml:78`)을 `Masc_tui_chart.bar` 하나로 모은다.
막대 옆에는 늘 숫자를 쓴다. 사용량 퍼센트에는 `사용` 을 붙인다. 지금 들어오는 사용량 값은 모두 사용한 비율이다
(`Runtime_provider_usage_window.utilization`).

## 6. 실시간과 추이

### 6.1 "지금" 패널 (D2)

지금 오른쪽 Activity 패널은 Keeper 23명을 전부 세로로 그린다. 그중 절반이 `no events` 다.
이 패널은 **지금 움직이는 것만** 보여 준다.

```
지금 · live 0.4s
◐ won-chik        turn 1882  2m42s  masc_dos_pass
◐ tui-developer   turn 625   1m37s  14 calls
! rondo           rate limited · 16:06:51 재시도
─ 최근 ─────────────────────────────
■ code-reviewer   turn 791  6.2s  no calls
× pr-updater      turn failed · antigravity_cli
쉬는 Keeper 12 · 오프라인 1
```

- 상태 어휘는 Keepers 목록과 같다(§4.2).
- 머리의 `HTTP [connected]` 대신 마지막 이벤트 뒤 지난 시간(`live 0.4s`)을 보여 준다.
  SSE 가 끊기면 `polling 2s` 로 바뀐다.
- 기본으로 켜는 폭은 지금 넓은 패널 기준(`Masc_tui_acting_pane.wide_threshold_cols`)이다. `Ctrl-L` 로 켜고 끈다.

### 6.2 계정 사용량

#38801 의 `Runtime_provider_usage_window` 를 그대로 쓴다. 창 종류는 이미 variant 다
(`Five_hour | Seven_day | Duration_minutes of int | Provider_label of string`).
그 모듈의 계약도 그대로 따른다. 사용량 숫자로 가용성을 짐작하지 않고, 제공자가 말한 것을 말한 대로 보여 준다.
초기화 시각이 지난 보고도 새 보고가 올 때까지 남긴다.

```
Usage · 계정                                   읽음 16:05:55 · 보고 시각은 줄마다
claude_code  scope a1  5h  ██████░░░░ 60% 사용 · 초기화 17:18 (1h12m 뒤) · 16:04 보고
                       7d  ██░░░░░░░░ 16% 사용 · 초기화 09-30 · 16:04 보고
codex        scope c1  7d  ██████████ 100% 사용 · 초기화 09-28 · 15:51 보고
glm-coding   scope g1  TIME_LIMIT (1 x unit 5)  0% 사용 · 초기화 시각 없음
antigravity  scope n1  서버 시작 뒤 보고 없음
```

- 이 RFC 는 새 창 타입을 만들지 않는다. 표시에 필요한 것이 없으면 #38801 의 타입에 더한다.
- 상태 글자(`소진`)는 제공자가 그 상태를 말했을 때만 쓴다. 100% 를 보고 소진이라고 짐작하지 않는다.
- `Provider_label` 은 제공자가 준 글자 그대로 그린다. Z.AI 의 `TIME_LIMIT`·`TOKENS_LIMIT` 과 `unit` 값을
  `Duration_minutes` 로 읽을 수 있는지는 Z.AI 공식 문서로 확인한 뒤 디코더에서 한다(확인 필요).
  화면에서 글자를 바꾸지 않는다.
- 초기화 시각이 지난 보고를 어떻게 보일지는 D9 다.
- 계정은 scope 로 구분한다. scope 는 사람 계정이 아니라 불투명한 ID 다(measured-home RFC 그대로).

### 6.3 추이 — 시간·일·주

차트 부품 하나와 범위 키 하나로 여러 범위를 본다. 범위마다 차트를 따로 그리지 않는다.

- 범위는 저장된 만큼만 둔다. 제공자 사용량 이력은 #38801 의 1·7·14일 창이 전부다.
  Keeper 턴 metrics 는 일 파일로 있고 보관 기간은 확인해야 한다. 그래서 `1h`(1분 칸), `24h`(1시간 칸),
  `7d`(6시간 칸), `14d`(1일 칸)로 시작한다. 월 범위는 D10 이다.
- 범위는 `+`/`-` 로 바꾼다(bottom 과 같은 키).
- 계열은 턴 수, 입력·출력 토큰, 도구 호출, 실패, 완료된 Task, 계정별 사용 비율이다.
- 칸을 채우는 규칙을 계열마다 적는다. 턴·토큰·호출·실패는 그 칸에 끝난 턴의 합이다.
  계정 사용 비율은 합이 아니라 그 칸의 마지막 보고다.
- 차트 밑에 같은 숫자를 표로 둔다. 숫자 없이 차트만 있는 칸은 없다.
- 보고가 없는 칸은 비워 두고 `보고 없음` 으로 센다. 0 으로 채우지 않는다.

서버에는 구간별 조회가 하나 필요하다.

```
GET /api/v1/dashboard/usage/series?range=1h|24h|7d|14d&by=keeper|provider|runtime
→ { range, bucket_seconds, buckets: [ { start, values: {...}, coverage: reported|partial|missing } ] }
```

- Keeper 턴·토큰·호출·실패는 Keeper metrics 일 파일에서 읽는다.
- 완료된 Task 는 #38784 가 남기는 완료 기록에서 읽는다.
- 계정 사용 비율은 #38801 의 `server_provider_usage_history` 에서 읽는다.
- 읽기 비용: 지난 날의 일 파일은 바뀌지 않으므로 날짜별로 한 번 읽어 계산해 둔다. 새로고침마다 다시 읽는 것은 오늘 파일뿐이다.
  24시간 상한이 있는 `keeper-costs` 는 이 조회와 별개로 둔다.

### 6.4 Dashboard 에 올리는 것

measured-home RFC 의 Dashboard 에 다음 세 줄만 더한다.

- `Awaiting you N` — Work 로 가는 링크
- 계정마다 사용 비율이 가장 높은 창 하나 — Usage 로 가는 링크
- 24h 턴 수 스파크라인과 14일 완료 Task 막대 — Usage › 추이로 가는 링크

## 7. 이름 정리 (Glossary 같이 고침)

| 지금 | 바꿀 이름 | 이유 |
|---|---|---|
| Approvals, Task Review, `Awaiting you`, `awaiting verdict` | Awaiting you (종류: 승인, 질문, Task 완료 요청, Goal 확인) | 한 질문에 네 숫자 |
| Task Review VERDICT 열 | REQUEST | 기다리는 판정의 종류지 내린 판정이 아니다 |
| Keeper 상세 Automation | Schedule | Glossary 는 Schedule 이다. `Browser_lane_view.Automation` 과도 겹친다 |
| Keeper 상세 Runs | (지움) | Work › Fusion 을 Keeper 로 거른 것과 같다 |
| 생성자 `Harness` | `Verdicts` | 화면 이름과 생성자 이름이 다르다 |
| Lanes 표의 SLOT | RUNTIME | Glossary 의 Slot 은 DOS 기계 체크포인트 이름이다 |
| Config `/preset` | Snapshot (D4) | Glossary 의 Preset 은 Fusion preset 이다 |
| `fleet ok` | `fleet ok` 그대로, degraded/blocked 일 때 이유를 붙임 | 종합 판정이다(§1.2) |
| Mode 열 `A M`, `D M` | 상세의 문장 | 설명 없는 한 글자다 |
| Memory 표 `ST`, `r2 i0`, `Δ` | `상태`, `recall 2 · 무효 0`, `최근 변화 +1 −3` | 설명 없는 약어다 |

## 8. 구현 순서 — 스택 PR

각 PR 은 출력 20k 토큰 이하로 나눈다(constitution `work_unit`). 로컬 Dune 빌드는 하지 않고 CI 로 확인한다.
병합은 Keeper 가 한다.

### 다른 세션이 이미 하는 것 (건드리지 않음)

| PR/이슈 | 내용 | 이 RFC 와의 관계 |
|---|---|---|
| #38801 | 7곳 탭, Dashboard, Usage 창 이력 | S4, S5 가 이 위에 쌓인다 |
| #39221, #39223 | 입력 해석기 하나 | S1 이 여기서 나온 마우스 이벤트를 쓴다 |
| #39209 | `Masc_tui_fetched` 에 Stale | S7 이 이 위에 쌓인다 |
| #39216 | 채팅 diff 구문 강조 | 그대로 |

### S1 — 누를 수 있는 곳 기록과 스크롤 위치 (먼저)

| # | 범위 | 확인 |
|---|---|---|
| S1-1 | `Masc_tui_hit` 모듈. 탭, 숨은 칸 표시, Keeper 상세 칸, Config 칸, Activity 칸을 누르면 그곳으로 간다. 표는 `Presented` 뒤에만 바꿔 넣는다 | 단위 테스트: 잘림·한글·SGR 을 지난 열. PTY: 탭 클릭으로 화면이 바뀜 |
| S1-1b | 나머지 하위 칸 띠(Planning, Runtime/Lanes, Metrics, Tools, Memory, Context inspector) | PTY: 칸 클릭 |
| S1-2 | `Masc_tui_viewport` 와 영역 variant. `surface_chrome` 을 쓰는 목록 28곳. 행 클릭(ID 로)과 휠 규칙 | 스크롤·커서 필드 수가 줄어든 것을 §9 명령으로 적음 |
| S1-3 | 상세 읽기(fact, 증거, 글, Task 상세, diff). §1.3 의 휠 결함이 여기서 없어진다 | PTY: 상세 위 휠이 상세를 움직임, `G` 뒤 마지막 줄이 보임 |
| S1-4 | `finish_surface` 를 직접 부르는 나머지를 옮기고, `Masc_tui_scroll` 자유 함수와 옛 필드를 지움. `lanes_overview_hit` 지움 | §9 의 스크롤 필드 수가 0 |
| S1-5 | 따라가기와 `↓ 새 항목 N` | PTY: 위로 올린 뒤 이벤트가 와도 화면이 안 움직임 |

### S2 — 복사와 링크 (D7 뒤)

| # | 범위 | 확인 |
|---|---|---|
| S2-1 | `copyable` variant, 복사 키, 상태 줄 알림. #39170 을 닫음 | PTY: 긴 줄과 빈 줄이 든 답장을 복사하면, OSC 52 base64 를 푼 값이 원문과 바이트까지 같음 |
| S2-2 | OSC 8 링크(URL, PR 번호, 로컬 경로) | PTY 캡처에 `ESC ] 8 ;;` 가 있음 |

### S3 — Keepers

| # | 범위 |
|---|---|
| S3-1 | Keeper 상태 variant 한 벌로 목록, Activity 패널, Dashboard 요약. fleet status 를 variant 로 읽고 이유를 보임 |
| S3-2 | Keepers 목록 묶어 보기와 `!` 문제만 보기 |
| S3-3 | 상세 9칸 → 7칸(§4.3). Runs 칸 지움 |
| S3-4 | 설정 칸: 연결된 것 먼저, 안 된 것은 접힌 한 줄. Schedule 칸: 닫힌 것 접기 |

### S4 — Work (#38801 병합 뒤, D5·D6 뒤)

| # | 범위 |
|---|---|
| S4-1 | `awaiting` variant 와 한 목록, 한 숫자. REQUEST 열 |
| S4-2 | 판정 키 이름 통일(#35885) |

### S5 — Usage 와 추이 (#38801 병합 뒤)

| # | 범위 |
|---|---|
| S5-1 | 계정 화면(§6.2)과 막대 하나(§5.8). #38801 의 타입에 필요한 것만 더함 |
| S5-2 | 서버 `usage/series` 조회와 날짜별 계산 저장 |
| S5-3 | 추이 차트와 범위 키, Dashboard 세 줄 |

### S6 — 틀린 값 바로잡기 (독립, main 기준, Keeper 에게 나눠 줄 수 있음)

| # | 범위 |
|---|---|
| S6-1 | 가격이 없는 턴을 0 으로 더하지 않는다. 생산자 쪽 비용을 "보고됨 / 보고 없음"으로 나누거나, Info 가 keeper-costs 합계를 읽는다 |
| S6-2 | Presets 목록과 상세가 같은 schema 규칙으로 읽는다. schema 1 은 목록에서도 "읽지 못함"으로 보인다 |
| S6-3 | fleet status 를 문자열 비교 대신 variant 로 읽고 색을 정한다 |
| S6-4 | `-> "?"` 10곳을 `Glyph.no_value` 로 바꾸고 이유를 같이 적는다 |

### S7 — 부품 모으기

| # | 범위 |
|---|---|
| S7-1 | `*_unread` 생성자 14개 → `Masc_tui_fetched` (#39209 뒤) |
| S7-2 | Fusion 상태 표기 3벌 → 1벌, 쿼터 소진 표기 3벌 → 1벌 |
| S7-3 | 글자 맞추기 함수를 `Message_layout` 로. 바이트를 세는 두 곳을 칸으로 |
| S7-4 | 직접 문자열 footer 힌트 14곳을 키 표로(#38987 의 일부). 그 뒤 footer 클릭 |

## 9. 확인 방법

- 각 PR 은 PTY 시나리오로 화면을 실제로 그려 확인한다. 마우스는 SGR 바이트(`ESC [ < b ; x ; y M`)를
  PTY 에 써서 보낸다.
- 부품 수를 PR 마다 같은 명령으로 잰다. 오른쪽 숫자는 `32e09f3db0` 기준이다.

  ```sh
  rg -c '^\s*mutable [a-z_0-9]*_scroll\s*:' bin/masc_tui_types.ml      # 51
  rg -c '^\s*mutable [a-z_0-9]*_cursor\s*:' bin/masc_tui_types.ml      # 45
  rg -o '\b[A-Z][a-z_]*_unread\b' bin/masc_tui_types.ml | sort -u | wc -l  # 14
  rg -n '~hints:"' bin/masc_tui_render.ml | wc -l                          # 14
  ```

- 스택이 끝나면 운영자 장비에서 같은 35장을 다시 찍어 §1 의 항목을 하나씩 대조한다.

### 참고 자료 (2026-09-26 확인)

- Claude Code agent view: https://code.claude.com/docs/en/agent-view
- Claude Code fullscreen(접기, 따라가기, 복사 경로): https://code.claude.com/docs/en/fullscreen
- Claude Code statusline rate_limits: https://code.claude.com/docs/en/statusline
- Amp 사이드바 제거(검색 요약으로만 확인): https://ampcode.com/news/so-long-tui-sidebar
- k9s(`ctrl-z`, `:` 인자, pulses): https://github.com/derailed/k9s
- bubblezone(폭 0 표식으로 클릭 위치 찾기): https://github.com/lrstanley/bubblezone
- bottom(범위 확대·축소): https://bottom.pages.dev/stable/usage/general-usage/
- Codex 사용량 퍼센트 표기: https://github.com/openai/codex/pull/24314
- 이미지 프로토콜 선택: https://yazi-rs.github.io/docs/image-preview/

## 10. 운영자가 정할 것

| # | 질문 | 제안 |
|---|---|---|
| D1 | 7곳으로 바로 가는 키를 맨 숫자로 할까, 다른 수정 키와 함께 할까 | 맨 숫자는 Activity·Metrics·Approvals·GitHub 칸이 이미 쓴다. `Alt` + 숫자를 제안한다. #39223 해석기가 Alt 를 구분하는지 확인이 먼저다 |
| D2 | "지금" 패널을 기본으로 켤 폭과 보여 줄 것 | 넓은 패널 기준 폭 이상에서 켜고, 움직이는 것만 보인다 |
| D3 | Memory 를 Keepers 안으로 넣을까, 따로 둘까 | Keepers 안. 목록에 Memory 열, 상세에 Memory 칸 |
| D4 | Config `/preset` 을 Snapshot 으로 바꿀까 | 바꾼다. Glossary 의 Preset 과 겹친다 |
| D5 | Work 의 Task Review 칸을 Awaiting you 목록으로 합칠까 | 합친다. measured-home 은 Task Review/Verdicts 를 따로 뒀다 |
| D6 | Fusion 과 Schedules 를 Work 로 옮길까 | 옮긴다. measured-home 은 둘을 정하지 않았다 |
| D7 | 복사 키 | 지금 `y`/`Y` 는 참조 복사와 승인 두 뜻이다. 판정 화면이 쓰지 않는 키(`Ctrl-Y`, `/copy`)를 제안한다 |
| D8 | 휠이 목록에서 선택을 옮길까, 화면만 옮길까 | 선택을 3행 옮긴다. 선택 행이 화면 밖으로 나가지 않는 규칙을 지킨다 |
| D9 | 초기화 시각이 지난 사용량 보고를 어떻게 보일까 | 값은 그대로 두고 흐리게 그리며 `초기화 시각 지남 · 새 보고 없음` 을 붙인다. 회복됐다고 쓰지 않는다 |
| D10 | 월 단위 추이 | Keeper metrics 일 파일 보관 기간을 확인한 뒤 정한다. 제공자 사용량 이력은 14일까지다 |

## 11. 하지 않는 것

- 최상위 7곳의 이름과 순서는 measured-home RFC 가 정했다. 다시 정하지 않는다.
- 입력 바이트 해석은 #39221 이 맡는다.
- Notty 같은 렌더 기반 교체는 하지 않는다(RFC-0459 에서 미룬 결정).
- Sixel 은 넣지 않는다. Kitty·iTerm2 이미지만 쓴다(지금과 같음).
- 사용량 숫자로 가용성을 짐작하는 표시는 만들지 않는다.
