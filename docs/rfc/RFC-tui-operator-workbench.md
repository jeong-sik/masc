---
rfc: "tui-operator-workbench"
title: "TUI 작업대 — 모든 화면이 같은 부품으로 클릭·스크롤·복사·추이를 받는다"
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
최상위 메뉴는 이미 `RFC-tui-measured-operator-home`(Accepted, 09-25)에서 7곳으로 정했다.
Dashboard, Work, Keepers, Usage, Board, Workspace, System 이다. 이 RFC 는 그 결정을 바꾸지 않는다.

이 RFC 가 정하는 것은 세 가지다.

1. **화면이 같은 부품을 쓴다.** 클릭, 휠, 창 읽기(`rows a–b/n`), 원문 복사, 접기·펼치기, 넓이 배분이다.
   지금은 화면마다 따로 구현해서 같은 결함이 화면을 옮겨 다닌다(§2).
2. **7곳 안의 배치를 정한다.** 지금 있는 23개 surface, Keeper 상세 9칸, Config 7칸이 어디로 가는지,
   무엇을 합치고 지우는지 한 표로 정한다(§4).
3. **실시간과 추이를 한 모양으로 보여 준다.** 계정별 사용량 창, 시간·일·주·월 추이,
   지금 도는 턴이다(§6).

구현은 스택 PR 로 나눈다(§8). 먼저 부품을 만들고, 그다음 화면을 옮긴다.

## 1. 화면에서 본 것

스크린샷은 운영자 장비에서 약 200×56 셀로 찍었다. 공개 저장소라 이미지 파일은 올리지 않는다.
아래는 관찰을 옮긴 것이고, 코드로 확인한 것은 위치를 적었다.

### 1.1 위계가 없다

- 최상위 10칸이 같은 무게로 나란히 있다. Config 는 하위 7칸이 있고,
  Runtime·Resources·Tools 는 탭에 없고 키(`9`, `s`, `t`)로만 간다.
- Keeper 상세는 9칸이다. 자주 쓰는 대화·호출·로그는 칸에 없고 키(Enter, `t`, `o`)로만 간다.
  드물게 쓰는 칸이 Info 와 같은 무게로 있다.
  - Identity: 서비스 89개가 전부 `not attached` 로 한 화면을 채운다.
  - Automation: 78행 중 1행만 예약 중이고 75행이 닫힌 예약이다.
  - Runs: `No retained Fusion runs` 한 줄이다.
- Task Review 103행의 VERDICT 열이 전부 `cancel` 이다. 이 열은 "이 행이 기다리는 판정 종류"(complete/cancel)인데
  (`bin/masc_tui_render_schedule.ml:693`), 머리글이 VERDICT 라서 이미 내린 판정으로 읽힌다.

### 1.2 같은 것을 여러 곳에서, 서로 다르게 말한다

| 사실 | 보이는 곳과 표기 |
|---|---|
| Keeper 상태 | 곁판 `open`/`done`/`no events` · Keepers `failing`/`offline`, Mode `A M` · Overview Team `need you`/`working`/`idle`/`no phase` · Memory `+`/`!` |
| 전체 건강 | Overview `Health: bad` · Keepers `fleet ok` 옆에 `8 failing`. `fleet ok` 는 턴 건강이 아니라 연결 불가 Keeper 수가 0이라는 뜻이다(`lib/server/server_routes_http_runtime_health_fleet.ml:117`). 색은 문자열 비교로 정한다(`bin/masc_tui_render.ml:5188`) |
| 운영자가 할 일 | 하단 `Awaiting you·104` · 탭 `Planning·103` · Overview `Approvals: 0` · Keepers `awaiting verdict 103` |
| 비용 | Keeper Info `Total Cost: $0.0000`, 같은 화면 24h 칸 `Cost: not priced by the provider`. 디코더가 없는 비용을 `0.` 으로 채운다(`lib/tui_decode.ml:1293`, 타입 `float`) |
| Fusion 실행 | Fusion 탭과 Keeper Runs 칸. 상태 표기 세 벌(`render_prim.ml:2393`, `render.ml:8107`, `render.ml:10672`) |
| 쿼터 소진 | 세 벌 표기(`render_prim.ml:2829`, `types.ml:10054`, `overview_providers.ml:200`). Overview Providers 는 제공자 원문 `TIME_LIMIT TIME_LIMIT, 1 x unit 5` 를 그대로 그리고, 초기화 시각은 `…` 로 잘린다 |

### 1.3 마우스와 스크롤

- 클릭이 되는 곳은 곁판, Lanes 목록, 채팅의 접힌 Gate 행, Browser Lane 화면뿐이다.
  탭, 제목 줄의 하위 칸, 목록 행, footer 키는 눌리지 않는다.
- Lanes 목록의 클릭 위치 계산은 크롬 7행을 손으로 센다(`bin/masc_tui_types.ml:9024`).
- 휠은 키 이름 `wheel-up`/`wheel-down` 으로 바뀌어 목록의 `j`/`k` 갈래로 간다(`bin/masc_tui.ml:18795`, `:23508`).
  목록에서는 커서가 1행 움직인다.
- Memory fact 상세와 Activity 증거 상세의 스크롤 갈래는 `j`/`k`/`down`/`up` 만 받는다(`bin/masc_tui.ml:21903`, `:21931`).
  휠은 이 갈래를 지나 뒤쪽 목록 커서를 움직인다. 코드로 확인했고 실측은 아직이다.
- 숫자 바로가기는 `2`(Keepers) 하나뿐이다. `p`, `v`, `9`, `[`/`]` 는 화면마다 뜻이 다르다.
- footer 는 대부분 화면에서 잘려 `…?` 로 끝난다.
- 원문을 복사할 길이 없다(#39170). 끌어서 복사하면 화면 폭 줄바꿈과 곁판 글자가 같이 딸려 온다.

### 1.4 실시간과 추이

- 기본 2초 폴링에 observer SSE 가 더해진다(`bin/masc_tui.ml:1014`, `bin/masc_tui_http.ml:78`).
  곁판이 호출 수와 새 토큰을 실시간으로 보여 주는 것은 잘 동작한다.
- 추이는 Overview Pulse 스파크라인과 Team 14일 막대 둘뿐이다. 시간·일·주·월로 바꿔 볼 곳이 없다.
- Keeper 비용 API 는 최대 24시간 창 하나를 합계로만 준다(`lib/dashboard/dashboard_http_keeper_feeds.ml:85`).
  Keeper 별 metrics 는 UTC 일 단위 파일로 이미 디스크에 있다.
- 제공자 사용량은 "서버 시작 이후"만 보인다. 계정별 일 단위 이력은 #38801 에 있고 아직 병합 전이다.

### 1.5 소음

- ID 와 경로가 행의 절반을 쓴다. Board ID 열, Lanes RUN ID 열, Channels 의 경로 9줄, Sandbox 경로 5줄이다.
- 설명 없는 한 글자 표식이 있다. `A M`, `D M`, `+`, `!`, `r2 i0`, `Δ +1 -3` 이다.
- Presets 목록은 schema 1 프리셋 7개를 요약까지 그린다. 그런데 상세는
  `HTTP 404: unsupported schema_version 1 (expected 2)` 로 읽지 못한다. 목록과 상세가 다른 규칙으로 읽는다.

## 2. 코드에서 본 것 — 1주 336커밋

2026-09-19부터 09-26까지 `bin/masc_tui*` 를 건드린 커밋이 336개다(+27.1k/−8.1k).
하루 최대 101개(09-23)다. 같은 결함을 화면 하나씩 고친 커밋이 많다.
Approvals 의 "못 읽음을 빈 목록으로 보임" 결함은 PR 9개에 걸쳐 고쳐졌다
(#38006 → #38284 → #38302 → #38666 → #38904 → #38917 → #39024 → #39172 → #39169).

| 부품 | 지금 몇 벌인가 | 정본 |
|---|---|---|
| 글자 맞추기·자르기·채우기 | 최상위 함수 약 24개 + 지역 함수 약 15개. 두 개는 칸이 아니라 바이트를 센다 | `Message_layout.fit_width` |
| 스크롤 상한 계산 | 정본 옆에 약 46곳. `render.ml` 의 35곳은 정본을 부르지 않는다 | `Masc_tui_scroll` |
| 스크롤·커서 상태 필드 | `mutable *_scroll` 51개, `mutable *_cursor` 45개(`bin/masc_tui_types.ml`) | 없음 |
| 막대·게이지 | 7개 | 없음 |
| "못 읽음" 생성자 | `Masc_tui_fetched` 옆에 `*_unread` 생성자 14개(이번 주 5개 추가) | `Masc_tui_fetched` |
| Keeper 목록을 그리는 곳 | 7곳, 상태 어휘 4벌 | 없음 |
| footer 힌트 | `~hints:"…"` 직접 문자열 14곳이 키 표를 지나친다 | `Masc_tui_keys` |
| 손으로 센 크롬 행 | `rows - 5`, `rows - 6`, `rows - (if editing then 10 else 7)` 등 6곳 | `count_frame_lines` |

**결론.** 화면 하나씩 고치는 PR 은 결함을 다음 화면으로 옮긴다. 부품을 먼저 하나로 모으고,
옛 부품은 같은 스택 안에서 지운다. 이것은 N-of-M 패치가 아니다. 타입이 먼저 들어오고,
컴파일러가 남은 자리를 전부 찾게 한다.

## 3. 원칙

1. **첫 화면은 두 질문에만 답한다.** "내가 지금 할 일이 있나"와 "잘 돌고 있나"다.
   (`RFC-tui-measured-operator-home` 그대로)
2. **한 개념은 한 곳에서, 한 이름으로 보인다.** 다른 곳에는 요약 한 줄과 그곳으로 가는 링크만 둔다.
   링크는 클릭과 Enter 가 같다.
3. **모든 목록은 같은 조작을 받는다.** 클릭은 선택, 두 번 클릭과 Enter 는 열기다.
   휠은 포인터 아래 영역을 스크롤한다. `rows a–b/n`, `/` 찾기, Home/End, PgUp/PgDn 을 모든 목록이 받는다.
4. **마우스로만 되는 일은 없다.** 클릭은 키보드가 보내는 것과 같은 typed action 으로 바뀐다.
5. **모르는 값은 모른다고 쓴다.** 0 으로도, `?` 로도 그리지 않는다(RFC-0462).
6. **원문이 먼저다.** 복사는 원문을 보낸다. 링크는 OSC 8 로 건다. 긴 것은 접고 펼친다.
7. **넓이는 예산에서 나눠 준다.** 열마다 우선순위를 선언하고, 좁아지면 선언된 순서로 뺀다(#38988).
8. **문자열로 분기하지 않는다.** 상태, 표식, 색은 variant 에서 나온다.

## 4. 7곳 안의 배치

### 4.1 지금 있는 곳 → 갈 곳

`surface` variant(`bin/masc_tui_types.ml:2838`) 23개와 하위 칸을 전부 적는다.
"합침"은 한 화면의 구역이 된다는 뜻이다. "지움"은 코드와 테스트를 같이 지운다는 뜻이다.

| 지금 | 갈 곳 | 처리 |
|---|---|---|
| Overview | Dashboard | #38801 이 바꾼다 |
| Acting(Events), System_logs(Logs) | System › Activity | 옮김 |
| Metrics(telemetry) | Usage › Telemetry | 옮김 |
| Keepers(목록) | Keepers | §4.2 로 목록을 묶음 보기로 바꿈 |
| Keepers 상세 9칸 | Keepers 상세 7칸 | §4.3 |
| Memory(Keeper 건강 표) | Keepers 목록의 Memory 열 + Keeper 상세 Memory 칸 | 합침. 결정 D3 |
| Memory(fleet facts) | Keepers › `:memory` | 합침 |
| Lanes(Standalone) + Runtime(Lanes, All runtimes) | System › Lanes | 한 화면 두 구역으로 합침 |
| Clients | System › Lanes 의 구역 | 합침 |
| Approvals | Work › Awaiting you | 합침 |
| Planning(Goals) | Work › Goals | 옮김 |
| Verification(Task Review) | Work › Awaiting you | 합침. 한 목록, 한 숫자 |
| Harness(Task Verdicts) | Work › Verdicts | 옮김. 생성자 이름 `Harness` 를 `Verdicts` 로 바꿈 |
| Schedules | Keeper 상세 Schedule 칸 + Work › Schedules | 옮김 |
| Fusion | Work › Fusion | 옮김. Keeper Runs 칸은 지움 |
| Board | Board | §5 부품만 적용 |
| Repositories, Code, Changes | Workspace | 그대로 |
| Config(7칸), Resources, Tools, Connectors | System › Config, Tools, Connectors | 옮김 |
| Activity 곁판(Recent/Changes) | "지금" 곁판 | §6.1 |

### 4.2 Keepers 목록 — 묶음 보기

Claude Code 의 agent view 처럼 상태로 묶어 전체 화면 표로 보여 준다.
곁판에 Keeper 수십 명을 세로로 두는 모양은 Amp 가 없앤 모양이다(§9 참고 자료).

```
Keepers 24                          needs you 1 · failing 8 · working 4 · idle 10 · offline 1
▾ Needs you (1)
  ● jazz-developer     task-1719  12h30m  질문 1개 대기
▾ Failing (8)                                                     ! 문제만 보기
  ! rondo              glm-5.3-flash  rate limited · 다음 시도 16:06:51   28회 연속
  ! context-reviewer   glm-5.3-flash  rate limited                         …
▾ Working (4)
  ◐ goo-yang-bong      task-1762  8m33s  tool_execute
▸ Idle (10)  ▸ Offline (1)
```

- 상태 어휘는 한 벌이다. `Keeper_health` variant 하나에서 목록, 곁판, Dashboard 요약이 모두 나온다.
- `!` 는 문제 있는 묶음만 보이게 켜고 끈다(k9s 의 `ctrl-z` 와 같은 역할).
- `A M` 같은 한 글자 열은 없앤다. 모드와 샌드박스는 상세 Info 에 말로 적는다.

### 4.3 Keeper 상세 — 9칸에서 7칸으로

자주 쓰는 것이 앞에 온다. 대화는 지금 Enter 로만 가는데, 칸으로 올린다.

| 새 칸 | 담는 것 | 지금 어디에 있나 |
|---|---|---|
| 대화 | 대화 기록, 접기·펼치기, diff, 이미지, 원문 복사 | `Keeper_message` 모드 |
| 호출 | 도구 호출과 영수증 | `t` 키의 Calls 모드 |
| 변경 | 파일 diff | Changes surface |
| 상태 | 현재 실패, 문맥 사용량, 24h 사용량, Board attention, Memory·Schedule 요약 | Info |
| Memory | 이 Keeper 의 fact 목록과 상세, Librarian 상태 | Memory surface |
| Schedule | 예약 중인 것 먼저, 닫힌 것은 접힌 한 줄(`닫힌 75개 · 성공 11 · 취소 64`) | Automation |
| 설정 | Settings, Sandbox, Secrets, GitHub, Identity, Channels 를 섹션으로. 연결된 것 먼저, 안 된 것은 접힌 한 줄(`서비스 89개 중 0개 연결`) | 6칸 |

로그(`o`)는 상태와 설정 칸에서 키로 연다.

### 4.4 Work — Awaiting you 한 목록

지금 `Awaiting you`, `Planning·N`, `Approvals`, `awaiting verdict` 가 서로 다른 숫자를 말한다.
Work 의 첫 칸을 **Awaiting you** 로 하고, 운영자 판단을 기다리는 것을 한 목록에 모은다.

```ocaml
type awaiting =
  | Approval of Tool_approval.t        (* 도구 호출 승인 *)
  | Question of Keeper_ask.t           (* Keeper 가 운영자에게 물은 것 *)
  | Task_request of { task : Task_id.t; request : [ `Complete | `Cancel ] }
  | Goal_confirmation of Goal_id.t     (* Awaiting_confirmation *)
```

- 하단 `Awaiting you·N`, 탭 배지, Dashboard 숫자는 모두 이 목록의 길이다.
- Task Review 의 VERDICT 열은 REQUEST 로 이름을 바꾼다. 값은 `complete`/`cancel` 이다.
- `y`/`n` 한 쌍으로 판정한다. 지금은 같은 y/n 을 Approve·confirm·decide·Allow 네 이름으로 부른다(#35885).

### 4.5 Usage — 계정, 추이, Keeper 사용량

§6.2 와 §6.3 에 적는다.

### 4.6 System — 설정과 기록

Activity(Events/Logs), Lanes, Config, Tools, Connectors 를 하위 칸으로 둔다.
Config 의 7칸(runtime.toml, models, params, prompts, presets, themes, voice)은 그대로 둔다.
Presets 는 §7 의 이름 바꾸기를 따른다.

## 5. 부품 — 모든 화면이 같이 쓰는 것

### 5.1 영역 지도 (`Masc_tui_hit`)

렌더러가 프레임을 그릴 때 "이 칸을 누르면 무엇인가"를 같이 적는다.
입력 쪽은 마지막으로 보여 준 프레임의 지도로 클릭과 휠을 해석한다.
지금 곁판만 가진 `acting_pane_row_targets`(`bin/masc_tui_render_prim.ml:81`)를 모든 화면으로 넓힌 것이다.

```ocaml
type region =                          (* 스크롤되는 영역. 닫힌 합타입 *)
  | Surface_body of Masc_tui_types.surface
  | Detail of detail_reader            (* fact 상세, 증거 상세, 글 읽기 … *)
  | Live_rail
  | Overlay of overlay

type target =
  | Destination of Masc_tui_types.surface   (* 탭 한 칸 *)
  | Sub_view of sub_view                    (* 제목 줄의 하위 칸 *)
  | Row of { region : region; index : int } (* 목록 한 행 *)
  | Key of Masc_tui_keys.action             (* footer 힌트 한 칸 *)
  | Fold of fold_id                         (* ▸ / ▾ *)
  | Link of link                            (* OSC 8 로도 건 대상 *)

type map
val record : map -> row:int -> first:int -> last:int -> target -> unit
val record_region : map -> rows:int * int -> cols:int * int -> region -> unit
val target_at : map -> row:int -> column:int -> target option
val region_at : map -> row:int -> column:int -> region option
```

- `surface_strip`, 제목 줄 하위 칸, `surface_chrome` 의 `push_selected` 와 행 push, footer fitter 가 기록한다.
  `surface_chrome` 을 부르는 곳이 28곳이다. `finish_surface` 를 직접 부르는 곳은 47곳이고(1곳은 `surface_chrome` 안),
  이것은 §8 S1 에서 옮긴다.
- 클릭은 `target` 을 키보드 action 으로 바꾼다. `Row` 한 번은 선택, 같은 행 두 번(400ms 안)은 열기다.
- 휠은 `region_at` 으로 포인터 아래 영역을 찾아 그 영역의 viewport 를 3행 움직인다.
  커서를 움직이는 것이 아니다. 목록에서 선택은 그대로 두고 창만 움직인다.
- `lanes_overview_hit` 의 손으로 센 7행은 지운다.
- 입력 해석은 #39223(`Masc_tui_input_decoder`)이 맡는다. 이 모듈은 거기서 나온
  `Mouse_left_press`, `Mouse_left_release`, `Mouse_wheel` 을 받아 쓰기만 한다.

### 5.2 Viewport (`Masc_tui_viewport`)

스크롤·커서 상태 필드 96개를 `region` 을 키로 하는 표 하나로 바꾼다.

```ocaml
type t = private {
  offset : int;          (* 창 첫 행 *)
  cursor : int option;   (* 선택 행. 읽기 전용 문서는 None *)
  length : int option;   (* 전체 행 수. 그리기 전에는 None *)
  page : int;            (* 창 높이 *)
  follow : follow;       (* 새 행이 오면 따라가나 *)
}
and follow = Following | Paused of { unseen : int }

val scroll : t -> by:int -> t
val move_cursor : t -> by:int -> t
val home : t -> t
val end_ : t -> t
val measured : t -> length:int -> page:int -> t  (* 프레임이 잰 값을 돌려준다 *)
val appended : t -> added:int -> t               (* 따라가거나 unseen 을 센다 *)
val reading : t -> string                        (* rows a–b/n, 모르면 rows a–b *)
```

- `max_int` 센티널과 `clamped_scroll` 되돌려 주기(`bin/masc_tui_types.ml:8691`)는 `length : int option` 으로 바꾼다.
  모르는 길이는 `None` 이다.
- 목록 키(j/k, PgUp/PgDn, Home/End, g/G, 휠)는 한 함수가 region 의 viewport 에 적용한다.
  화면별 `j`/`k` 갈래는 지운다.
- 따라가기: Activity, Board, Lanes 실행 목록, 채팅처럼 자라는 목록은 맨 아래에 있을 때만 따라간다.
  위로 올리면 멈추고 `↓ 새 항목 3` 을 보여 준다. 누르면 맨 아래로 간다.
- 마지막 PR 에서 `Masc_tui_scroll` 의 자유 함수와 `*_scroll`/`*_cursor` 필드를 지운다.

### 5.3 키 표 (#38987)

footer, 도움말, 키 처리가 하나의 typed 키 표를 본다. 이 RFC 는 에픽 #38987 의 범위를 그대로 따른다.
추가로 정하는 것:

- 최상위 7곳 바로가기는 `Alt-1`…`Alt-7` 이다. 지금 `Meta-2` 가 있다. 숫자만 누르는 키는 화면 안의 뜻을 그대로 둔다.
  (결정 D1)
- `:` 팔레트는 인자를 받는다. `:keeper rondo`, `:task 1738`, `:board p-…`, `:go System/Config/params` 이다.
- footer 는 한 줄이고, 들어가지 않는 키는 `?` 시트에만 있다. `…?` 표시는 그대로 둔다.

### 5.4 넓이 예산 (#38988)

`Table.cell` 에 우선순위와 최소 폭을 더한다. 좁아지면 우선순위가 낮은 열부터 뺀다.
손으로 센 폭 상수(최상위 156개 중 74개가 `render_schedule.ml`)는 이 예산으로 옮긴다.
ID 열은 기본 우선순위를 가장 낮게 둔다. ID 는 `Y` 로 복사한다(§5.6).

### 5.5 읽기 상태 하나 (`Masc_tui_fetched`)

`Approval_unread`, `Board_list_unread`, `Goals_unread`, `Lane_list_unread`, `Local_workspace_unread`,
`Overview_pulls_unread`, `Overview_spend_unread`, `Page_unread`, `Providers_unread`, `Quota_unread`,
`Rows_unread`, `Spend_rows_unread`, `Spend_unread`, `Workspace_identity_unread` 14개를
`Masc_tui_fetched.t` 하나로 바꾼다. #39209 가 여기에 `Stale`(이전 값 + 실패)을 넣는다.
화면은 네 상태를 같은 모양으로 그린다: 읽는 중, 값, 값 + `오래됨 3m · 새로고침 실패`, 못 읽음 + 이유.

### 5.6 복사와 링크

- `y`: 선택한 것의 **원문**을 OSC 52 로 보낸다. 메시지 Markdown, fact 문장, 글 본문, 로그 한 줄, diff 이다.
- `Y`: 선택한 것의 ID 나 링크를 보낸다.
- 보낸 뒤 상태 줄에 `복사함 · 1,204자 · OSC 52` 를 남긴다. OSC 52 가 닿았는지는 터미널이 알려 주지 않으므로
  "보냈다"고만 쓴다.
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
- 마우스를 터미널에 돌려주는 `Ctrl-T` 는 그대로 둔다. 도움말에 Shift/Option 끌기로도 선택할 수 있다고 적는다.

### 5.7 접기·펼치기와 넓게 보기

- `▸`/`▾` 는 `Fold of fold_id` 대상이다. 클릭, Enter, Space 가 같다.
- 채팅의 추론(Ctrl-R), 도구 상세(Ctrl-D), 턴 접기(Ctrl-S)는 그대로 두고, 같은 `fold_id` 로 클릭도 받는다.
- `z` 는 선택한 영역을 화면 전체로 넓힌다. Board 의 `z:wide` 를 모든 상세로 넓힌 것이다.

### 5.8 막대 하나

막대·게이지 7벌(`ansi.ml:747`, `chart.ml:135`, `context_bars.ml:137/143/162`,
`overview_providers.ml:43`, `overview_goals.ml:78`, `footer.ml:656`)을 `Masc_tui_chart.bar` 하나로 모은다.
막대는 항상 숫자와 같이 그린다. 퍼센트에는 `사용`/`남음` 을 붙인다.

## 6. 실시간과 추이

### 6.1 "지금" 곁판

지금 곁판은 Keeper 23명을 전부 세로로 그린다. 그중 절반이 `no events` 다.
곁판은 **지금 움직이는 것만** 보여 준다.

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
- 150칸 미만에서는 기본으로 숨긴다. `Ctrl-L` 로 켜고 끈다(지금과 같음). (결정 D2)

### 6.2 계정 사용량

제공자마다 창 모양이 다르다. Claude 는 5h/7d, GLM 은 5h 와 구독 시작일 기준 주간,
Kimi 신규 가입은 5h 와 월간, Ollama 는 월간 크레딧, Antigravity 는 모델별 쿼터다.
그래서 고정 열이 아니라 **계정마다 창 목록**으로 그린다.

```ocaml
type window_kind = Rolling_hours of int | Weekly | Monthly | Daily | Credits | Per_model of string
type direction = Used | Left
type window = {
  kind : window_kind;
  percent : float option;          (* 제공자가 준 값. 없으면 None *)
  direction : direction;           (* 제공자가 준 방향 *)
  resets_at : float option;
  observed_at : float;
  state : [ `Ok | `Near | `Exhausted | `Unknown ];
}
type account = { provider : string; scope : string; windows : window list }
```

```
Usage · 계정                                          읽음 16:05:55
claude_code  (scope a1)  5h  ██████░░░░ 60% 사용 · 1h12m 뒤 초기화
                         7d  ██░░░░░░░░ 16% 사용 · 4일 뒤 초기화
codex        (scope c1)  7d  ██████████ 100% 사용 · 소진 · 2일 뒤 초기화
glm-coding   (scope g1)  5h  ░░░░░░░░░░ 0% 사용 · 토큰 5h 7% 사용
antigravity  (scope n1)  보고 없음 · 서버 시작 뒤 아직 안 읽음
```

- 제공자 원문(`TIME_LIMIT`, `usage (provider resetTime)`)은 화면에 그리지 않는다. 디코더가 `window_kind` 로 바꾼다.
  바꾸지 못하면 decode 실패로 남기고, 원문은 상세에서만 보인다.
- 초기화 시각은 남은 시간으로 쓰고, 지나면 그 창을 `초기화됨 · 새 보고 대기` 로 바꾼다.
- 계정은 scope 로 구분한다. scope 는 사람 계정이 아니라 불투명한 ID 다(measured-home RFC 그대로).

### 6.3 추이 — 시간·일·주·월

한 차트 부품과 범위 키 하나로 네 범위를 본다. 네 개의 차트를 따로 그리지 않는다.

- 범위: `1h`(1분 칸), `24h`(1시간 칸), `7d`(6시간 칸), `30d`(1일 칸). `+`/`-` 로 바꾼다(bottom 과 같은 키).
- 계열: 턴 수, 입력·출력 토큰, 도구 호출, 실패, 완료된 Task, 계정별 사용 퍼센트.
- 차트 밑에 같은 숫자를 표로 둔다. 차트만 있고 숫자가 없는 칸은 없다.
- 보고가 없는 칸은 비워 두고 `보고 없음` 으로 센다. 0 으로 채우지 않는다.

서버에는 구간별 조회가 하나 필요하다.

```
GET /api/v1/dashboard/usage/series?range=1h|24h|7d|30d&by=keeper|provider|runtime
→ { range, bucket_seconds, buckets: [ { start, values: {...}, coverage: reported|partial|missing } ] }
```

- Keeper 턴·토큰·도구 호출은 Keeper metrics 일 파일에서 읽는다(이미 있음).
- 완료된 Task 는 #38784 가 남기는 완료 기록에서 읽는다.
- 계정 사용량 이력은 #38801 의 `server_provider_usage_history` 에서 읽는다.
- 기존 `keeper-costs` 의 24시간 상한은 이 조회와 별개로 둔다.

### 6.4 Dashboard 에 올리는 것

measured-home RFC 의 Dashboard 에 다음 세 줄만 더한다.

- `Awaiting you N` — Work 로 가는 링크
- 계정마다 가장 급한 창 하나(`codex 7d 100% 사용 · 2일 뒤`) — Usage 로 가는 링크
- 24h 턴 수 스파크라인과 14일 완료 Task 막대 — Usage › 추이로 가는 링크

## 7. 이름 정리 (Glossary 같이 고침)

| 지금 | 바꿀 이름 | 이유 |
|---|---|---|
| Approvals, Task Review, `Awaiting you`, `awaiting verdict` | Awaiting you (종류: Approval, Question, Task request, Goal confirmation) | 한 질문에 네 숫자 |
| Task Review VERDICT 열 | REQUEST | 기다리는 판정 종류지 내린 판정이 아니다 |
| Keeper 상세 Automation | Schedule | Glossary 는 Schedule. `Browser_lane_view.Automation` 과도 겹친다 |
| Keeper 상세 Runs | (지움) | Work › Fusion 과 같은 목록 |
| 생성자 `Harness` | `Verdicts` | 화면 이름과 생성자 이름이 다르다 |
| Lanes 표의 SLOT | RUNTIME | Glossary 의 Slot 은 DOS 기계 체크포인트 이름이다 |
| Config `/preset` | Snapshot (결정 D4) | Glossary 의 Preset 은 Fusion preset 이다 |
| `fleet ok` | `연결 23/23` | 턴 건강이 아니라 연결 여부다 |
| Mode 열 `A M`, `D M` | 상세 Info 의 문장 | 설명 없는 한 글자 |
| Memory 표 `ST`, `r2 i0`, `Δ` | `상태`, `recall 2 · 무효 0`, `최근 변화 +1 −3` | 설명 없는 약어 |

## 8. 구현 순서 — 스택 PR

각 PR 은 출력 20k 토큰 이하로 나눈다(constitution `work_unit`). 로컬 Dune 빌드는 하지 않고 CI 로 확인한다.
병합은 Keeper 가 한다.

### 다른 세션이 이미 하는 것 (건드리지 않음)

| PR/이슈 | 내용 | 이 RFC 와의 관계 |
|---|---|---|
| #38801 | 7곳 탭 링, Dashboard, Usage 창 이력 | S4, S5 가 이 위에 쌓인다 |
| #39221, #39223 | 입력 해석기 하나 | S1 이 이 이벤트를 받아 쓴다 |
| #39209 | `Masc_tui_fetched` 에 Stale | S7 이 이 위에 쌓인다 |
| #39216 | 채팅 diff 구문 강조 | 그대로 |

### S1 — 영역 지도와 viewport (먼저)

| # | 범위 | 확인 |
|---|---|---|
| S1-1 | `Masc_tui_hit` 모듈. 탭 띠, 제목 줄 하위 칸, `surface_chrome` 행이 기록한다. 클릭 → typed action. 휠 → 포인터 아래 region. `lanes_overview_hit` 손 계산 지움 | PTY: 탭 클릭으로 화면이 바뀜, 행 클릭으로 선택, 상세 위 휠이 상세를 움직임(§1.3 결함) |
| S1-2 | `Masc_tui_viewport` + region 표. `surface_chrome` 목록 28곳을 옮김 | 옛 `*_scroll` 필드 수가 줄어든 것을 `rg -c` 로 적음 |
| S1-3 | 상세 읽기(fact, 증거, 글, Task 상세, diff)를 옮김 | PTY: `G` 뒤 마지막 줄이 보임, 휠이 같은 폭으로 움직임 |
| S1-4 | 나머지 `finish_surface` 직접 호출을 옮기고 `Masc_tui_scroll` 자유 함수와 옛 필드를 지움 | 아래 §9 의 스크롤 필드 수가 0 |
| S1-5 | 따라가기와 `↓ 새 항목 N` | PTY: 위로 올린 뒤 이벤트가 와도 창이 안 움직임 |

### S2 — 복사와 링크

| # | 범위 | 확인 |
|---|---|---|
| S2-1 | `copyable` variant, `y`/`Y`, 상태 줄 알림. #39170 을 닫음 | PTY: 긴 줄과 빈 줄이 든 답장을 복사하면 OSC 52 base64 를 푼 값이 원문과 바이트까지 같음 |
| S2-2 | OSC 8 링크(URL, PR 번호, 로컬 경로) | PTY 캡처에 `ESC ] 8 ;;` 가 있음 |

### S3 — Keepers

| # | 범위 |
|---|---|
| S3-1 | `Keeper_health` 한 벌로 목록, 곁판, Dashboard 요약. `fleet ok` → `연결 N/M` |
| S3-2 | Keepers 목록 묶음 보기와 `!` 문제만 보기 |
| S3-3 | 상세 9칸 → 7칸(§4.3). Runs 칸 지움 |
| S3-4 | 설정 칸: 연결된 것 먼저, 안 된 것은 접힌 한 줄. Schedule 칸: 닫힌 것 접기 |

### S4 — Work (#38801 병합 뒤)

| # | 범위 |
|---|---|
| S4-1 | `awaiting` variant 와 한 목록, 한 숫자. REQUEST 열 |
| S4-2 | `y`/`n` 한 쌍으로 판정 이름 통일(#35885) |

### S5 — Usage 와 추이 (#38801 병합 뒤)

| # | 범위 |
|---|---|
| S5-1 | 디코더: 제공자 원문 → `window_kind`, `direction`. 모르면 decode 실패 |
| S5-2 | 계정 화면(§6.2)과 막대 하나(§5.8) |
| S5-3 | 서버 `usage/series` 조회 |
| S5-4 | 추이 차트와 범위 키, Dashboard 세 줄 |

### S6 — 틀린 값 바로잡기 (독립, main 기준, Keeper 에게 나눠 줄 수 있음)

| # | 범위 |
|---|---|
| S6-1 | `k_total_cost_usd : float` → `float option`. 없으면 `가격 보고 없음` |
| S6-2 | Presets 목록과 상세가 같은 schema 규칙으로 읽음. schema 1 은 목록에서도 읽지 못한 항목으로 보임 |
| S6-3 | fleet 줄 색을 `fs_status` 문자열 비교 대신 variant 로 |
| S6-4 | `-> "?"` 10곳을 `Glyph.no_value` 로. 이유를 같이 적음 |

### S7 — 부품 모으기

| # | 범위 |
|---|---|
| S7-1 | `*_unread` 생성자 14개 → `Masc_tui_fetched` (#39209 뒤) |
| S7-2 | Fusion 상태 표기 3벌 → 1벌, 쿼터 소진 표기 3벌 → 1벌 |
| S7-3 | 글자 맞추기 함수를 `Message_layout` 로. 바이트를 세는 두 곳을 칸으로 |
| S7-4 | 직접 문자열 footer 힌트 14곳을 키 표로(#38987 의 일부) |

## 9. 확인 방법

- 각 PR 은 PTY 시나리오로 화면을 실제로 그려 확인한다. 마우스는 SGR 바이트(`ESC [ < b ; x ; y M`)를
  PTY 에 써서 보낸다.
- 부품 수를 PR 마다 같은 명령으로 잰다. 시작 값은 §2 의 표다.

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
- Amp 사이드바 제거: https://ampcode.com/news/so-long-tui-sidebar
- k9s(`ctrl-z`, `:` 인자, pulses): https://github.com/derailed/k9s
- bottom(범위 확대·축소): https://bottom.pages.dev/stable/usage/general-usage/
- Codex 사용량 방향 표기: https://github.com/openai/codex/pull/24314
- GLM 사용량 규칙 변경: https://docs.z.ai/devpack/notice/usage-revision
- Kimi 멤버십 창: https://www.kimi.com/code/docs/en/kimi-code/membership.html
- 이미지 프로토콜 선택: https://yazi-rs.github.io/docs/image-preview/

## 10. 운영자가 정할 것

| # | 질문 | 제안 |
|---|---|---|
| D1 | 7곳 바로가기를 숫자만으로 할까, Alt-숫자로 할까 | Alt-숫자. 숫자만은 Activity·Metrics·Approvals·GitHub 칸이 이미 쓴다 |
| D2 | "지금" 곁판의 기본값 | 150칸 이상에서만 켜고, 움직이는 것만 보인다 |
| D3 | Memory 를 Keepers 안으로 넣을까, 따로 둘까 | Keepers 안. 목록에 Memory 열, 상세에 Memory 칸 |
| D4 | Config `/preset` 을 Snapshot 으로 바꿀까 | 바꾼다. Glossary 의 Preset 과 겹친다 |

## 11. 하지 않는 것

- 최상위 7곳의 이름과 순서는 measured-home RFC 가 정했다. 다시 정하지 않는다.
- 입력 바이트 해석은 #39221 이 맡는다.
- Notty 같은 렌더 기반 교체는 하지 않는다(RFC-0459 에서 미룬 결정).
- Sixel 은 넣지 않는다. Kitty·iTerm2 이미지만 쓴다(지금과 같음).
