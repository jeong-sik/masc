---
rfc: "tui-chat-boundary-continuity"
title: "Keeper 채팅 화면 — 대화는 이어지게, 계기판은 경계 안으로"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["tui-operator-ia", "chat-turn-rail-and-side-lanes"]
---

# RFC: Keeper 채팅의 경계와 연속 (tui-chat-boundary-continuity)

## 0. Summary

Keeper 채팅 화면을 운영자가 2026-09-12 에 판정했다. 지적 12건이 나왔고, 전수
추적한 결과 하나의 원인으로 모인다.

> **확정된 대화는 흐름 밖으로 나가 있고, 지금 상태는 흐름 안에 섞여 있다.**

화면에는 성격이 다른 세 가지가 있다. ① 이미 일어난 대화 ② 지금 이 순간의 계기판
③ 내가 입력하는 자리. 지금은 셋이 한 박스 안에서 같은 밀도로 그려지고, 그 결과
둘이 서로 자리를 바꿨다. 진행 중인 내 말은 transcript 밖 고정 슬롯에 그려져
시간순이 깨지고(§2-3), `FAILOVER IN PROGRESS` 는 대화가 아닌데 대화 자리를 지나
입력줄에 붙는다(§2-1).

운영자가 "내 입력이 아직 런타임에 도달 못한 것 같다" 고 읽은 것은 오해가 아니라
화면이 실제로 그렇게 말하고 있었다. 계기판이 입력줄 바로 위에 붙으면, 그 실패가
내 입력에 걸린 것으로 읽힌다.

이 RFC 는 (A) 세 영역의 경계를 정하고 (B) 무엇을 연속으로 이어 붙이고 무엇을
경계 안에 가둘지 판정하며 (C) PR 절단선을 정한다.

데이터 문제가 아니다. 필요한 값은 전부 이미 저장되고 대부분 이미 그려진다.
배치의 문제다.

## 1. 현재 실측 (2026-09-12, main e5ef1c0ab1)

### 1.1 그리는 순서

`keeper_message_pane` 이 한 박스 안에 위에서 아래로 쌓는다.

| # | 내용 | 성격 | 코드 |
|---|---|---|---|
| 1 | 확정 transcript | 과거 | `masc_tui_render.ml` 히스토리 루프 |
| 2 | 메모리 journal 행 | 과거 | :10520-10530 |
| 3 | 읽기 위치 / older 로딩 | 계기판 | :10546-10565 |
| 4 | promoted USER(보냈고 실행 중) | **대화** | :10330-10345 |
| 5 | NEXT(대기 중인 내 말) | **대화** | :10358-10405 |
| 6 | Progress / Attention / Approval | 계기판 | :10650-10676 |
| 7 | AT THE GATE | 계기판 | :10680-10730 |
| 8 | 미등록 경고 | 계기판 | :10735-10745 |
| 9 | composer | 입력 | :10750-10775 |
| 10 | footer | 입력 보조 | :10780- |

4·5 는 대화인데 1 과 떨어져 있다. 6·7·8 은 계기판인데 9 에 붙어 있다.

### 1.2 결과로 나온 시간 역전

운영자 화면에서 실제로 관측된 순서다.

```
[14:05:54]  × ERROR   Rate limited        ← transcript(확정)
[14:05:18]  ▶ YOU  sent · …               ← promoted(고정 슬롯), 36초 앞선 사건이 뒤에
 NEXT 1 · 14:06:26 · behind this Keeper's running turn
```

`14:05:54` 가 `14:05:18` 위에 있다. 두 행이 다른 층에서 그려지기 때문이고,
층마다 시간축이 따로 있기 때문이다.

### 1.3 잘리는 행

`phase_text`(`masc_tui_keeper_chat_transcript.ml:1066-1120`)는 한 행에
`runtime_tag · N tools · still running: … · in this call … · <tool mix>` 를 잇는다.
화면에서는 다음처럼 끝났다.

```
⠻ FAILOVER IN PROGRESS · failover [glm-coding.glm-5.3-flash] (attempt 1) · 3 tools · still running: keeper_analyze~
```

경과 시간(`in this call`)과 tool mix 가 잘렸다. "느린가 멈췄나" 를 답하려고 붙인
값이 정확히 그 자리에서 사라진다. 잘림은 폭이 모자랄 때 **뒤쪽부터** 버리는데,
우선순위는 그 반대다.

### 1.4 토글 상태가 한쪽에서만 보인다

`chat_visibility_summary`(`masc_tui_types.ml:283-316`)는 기본값이면 라벨을
생략한다.

```ocaml
| Tools_compact -> None
| Tools_full -> Some "tools:full"
```

`Ctrl-D` 로 껐을 때 헤더에서 `tools:full` 이 사라질 뿐, "지금 compact 다" 라고는
아무 데서도 말하지 않는다. 운영자가 "어떨 때는 나오고 어떨 때는 안 나온다" 고
읽은 이유다. 같은 파일 :341 의 keeper 헤더 주석은 정반대 원칙을 적어 뒀다 —
"기본값을 포함해 유효한 stance 를 보여준다. 여기서 빈 라벨은 반복보다 나쁘다."
한 파일 안에 두 철학이 공존한다.

### 1.5 로스터 pane 이 기본으로 켜져 있다

`roster_pane_hidden = false`(`masc_tui_types.ml:4969`). `Ctrl-B` 로 접는다.
`Ctrl-L` Activity pane 이 "모든 keeper 가 지금 무엇을 하는가" 를 이미 답하고
(`masc_tui_keys.ml:38-40`), 채팅 화면의 좌측 목록은 이름만 나열한다. 겹친다.

### 1.6 실패가 어디서 났는지 모른다

`persisted_error_reply`(`lib/server/server_routes_http_keeper_stream.ml:1388`)는
provider 원문을 그대로 잇는다.

```ocaml
"Keeper request failed: " ^ detail
```

화면에는 `Rate limited: Rate limit reached for requests` 만 남는다. 같은 화면
헤더는 `failing claude_code.claude-sonnet-5` 라 하고 하단은
`failover [glm-coding.glm-5.3-flash]` 라 한다. **어느 쪽 한도인지 에러 행만으로는
알 수 없다.** 복구 시각도 없어서 재시도가 언제 의미를 갖는지 판단할 근거가 없다.

### 1.7 diff 는 기본 경로에서 닿지 않는다

`Keeper_chat_diff.rows` 는 compact 모드에서 입력 projection 을 그대로 돌려준다
(`masc_tui_keeper_chat_diff.mli:38-46`). compact 가 기본값이므로 기본 상태에서
diff 는 없다. `Ctrl-D` → `Tools_full` → `launch_keeper_chat_tool_details_load`
(`masc_tui.ml:4901`) → `launch_keeper_chat_file_changes_load` 로 이어져야 보인다.
경로는 살아 있으나 발견성이 없다. 헤더의 `diff_status` 는 `Tools_full` 일 때만
그려지므로(`masc_tui_render.ml:9744`), compact 에서는 "볼 게 있는지" 조차 말하지
않는다.

참고: `RFC-tui-operator-ia` §6-4 는 "부분 커버리지 필드는 렌더 지점이 없다" 고
적었다. 그 뒤 `diff_status` 가 생겨 지금은 렌더된다. 그 항목은 해소됐다.

## 2. 운영자 지적 12건 → 원인

| # | 지적 | 판정 | 원인 |
|---|---|---|---|
| 1 | 입력창에 failover/working 이 붙어 내 입력이 안 간 것 같다 | 설계 | §1.1 6·7 이 9 에 인접 |
| 2 | 메시지가 두 번 나온다 | **오해** | 중복 아님. 세 층이 각기 다른 메시지(§1.1 1·4·5) |
| 3 | 상태가 사방팔방 파편 | 설계 | §1.2 시간 역전 |
| 4 | 좌측 Keepers 가 Ctrl-L 과 중복 | 설계 | §1.5 |
| 5 | trace id 열이 행렬을 깨뜨린다 | 설정 | `Origin_row` 상태. `Ctrl-F` 순환 |
| 6 | broadcast·gate 가 늘 나와야 하나 | 설계 | §1.1 7 이 무조건 행 차지 |
| 7 | still running 이 정말 still running 인가 | **버그 확정** | §3.6 — 버려진 attempt 의 호출을 계속 센다 |
| 8 | rate limit 이 어디서 나는가 | 버그급 누락 | §1.6 |
| 9 | Ctrl-D 가 될 때도 안 될 때도 | 버그 | §1.4 |
| 10 | 계속 실패하는데 왜 계속 재시도 | **범위 밖** | runtime lane 정책. TUI 아님 |
| 11 | 코드 diff 를 못 본다 | 발견성 | §1.7 |
| 12 | 아이콘으로 아껴 쓸 수 없나 | 설계 | §3.4 |

12건 중 TUI 에서 닫는 것은 9건이다. #7 은 조사가 먼저고, #10 은 다른 레이어다.

## 3. 설계

### 3.1 세 영역

화면을 위에서 아래로 세 영역으로 나눈다. **영역의 행 수가 프레임마다 변하지
않는다** — 지금은 상태 행 개수에 따라 composer 가 위아래로 움직인다.

```
┌ 헤더 ─ keeper · stance · 모드 ────────────────┐  고정 2행
│                                               │
│  대화 — 하나의 시간축, 하나의 스크롤            │  나머지 전부
│                                               │
├─ 계기판 ─────────────────────────── 접힘/펼침 ┤  고정 1행 (펼치면 N행)
│  > 입력                                       │  1~N행
└─ footer ─────────────────────────────────────┘  고정 1행
```

경계는 **계기판과 대화 사이**에 있다. 지금은 없는 자리다.

### 3.2 연속으로 둘 것 — 대화

확정 transcript, 보냈고 실행 중인 내 말, 대기 중인 내 말을 **한 시간축에**
둔다. promoted 와 NEXT 를 고정 슬롯에서 빼서 transcript 꼬리에 붙인다.

상태는 자리가 아니라 표시로 구분한다.

```
[14:05]  ▶ YOU   ..?                      ⋯ 보냄, 답하는 중
[14:06]  ▶ YOU   continue                 ⋯ 대기 (앞의 턴 뒤)
```

운영자가 "타이핑하는 곳 위로 올라가서 새 대화가 만들어지는 듯 표현해야 하나"
라고 물은 것에 대한 답이다. **표현한다. 단 대화만, 계기판은 빼고.** 그 자리가
불편했던 것은 대화가 올라가서가 아니라 계기판이 같이 올라가 있어서다.

근거: 단일 에이전트 TUI 4종(pi·Claude Code·Hermes·Kimi)이 수렴한 모양이
"단일 스트림 + 접힌 tool 행 + 상태 바" 다(`RFC-tui-operator-ia` §5). 스트리밍
중인 답을 스트림 안에 두는 것이 그 4종의 공통점이다.

### 3.3 경계 안에 둘 것 — 계기판

Progress · Attention · Gate · 미등록 경고를 **한 행으로 접는다**. 기본은 한 행,
키 하나로 펼친다.

```
접힘:  ⠻ failover 2/3 · glm-5.3-flash · 3 tools · 1 out 1m12s · gate 1     ^S
펼침:  ┌─ TURN ────────────────────────────────────────────┐
       │ failover   attempt 2/3   (rate limit, resets 40m) │
       │ runtime    glm-coding.glm-5.3-flash               │
       │ tools      3 · keeper_analyze_image out 1m12s     │
       │ gate       1 judging 40s                          │
       └───────────────────────────────────────────────────┘
```

`AT THE GATE` 가 무조건 한 행을 차지하던 것(#6)은 접힘 행의 `gate 1` 칩이 된다.
멘션이나 사람 입력이 필요한 것만 펼침 없이 올라온다.

### 3.4 같은 말을 두 번 하지 않는다

§1.3 의 잘림을 다시 재 보니 원인은 순서가 아니라 **중복**이었다. 한 행이 상태를
두 번 말한다.

```
⠻ FAILOVER IN PROGRESS · failover [glm-coding.glm-5.3-flash] (attempt 1) · 3 tools · …
  └ progress_heading (render.ml)   └ runtime_tag (transcript.ml)
```

`progress_heading` 과 `runtime_tag` 는 둘 다 `attempt > 0` 을 보고 각자
"failover" 를 말한다. 제 fact 에 닿기도 전에 예순여섯 칸을 쓰고, 그래서 맨 뒤의
경과 시간이 떨어진다.

tag 에서 heading 이 이미 말한 것을 뺀다. heading 이 못 말하는 것 — 어느 runtime
이고 몇 번째 시도인지 — 만 남긴다.

```
전:  failover [glm-coding.glm-5.3-flash] (attempt 1) ·     48칸
후:  [glm-coding.glm-5.3-flash] attempt 1 ·                 38칸
```

**순서는 건드리지 않는다.** `still running: <이름들> · in this call <age>` 의
차례는 #32955 가 정한 것이고, 이름과 경과 시간은 같은 call 을 설명하므로 붙어
읽혀야 한다(`test_the_open_call_age_sits_with_the_names`). 그 판단은 유효하다.
줄일 것은 그 앞이다.

이래도 좁은 폭에서는 여전히 잘린다. 이름 목록에 상한을 두는 것(`still running:
Read, Bash +2`)은 PR 2 의 접기와 같은 자리라 거기서 함께 한다.

### 3.5 색에 기대지 않는다

ERROR 가 지금은 빨강 하나로만 구분된다. 형태를 같이 준다 — 확정 실패는 `×`,
진행 중은 회전 글리프, 대기는 `⋯`. 16색에서도 읽히고, 색을 다 빼도 읽힌다.

문자 가중치(`█▓▒░`)로 위계를 주는 것은 rate limit 잔량처럼 **양이 있는 값**에만
쓴다. 장식으로 쓰지 않는다.

### 3.6 still running 의 진위 — 조사 선행

`phase_text` 는 `Started | Awaiting_result` 인 도구만 센다
(`masc_tui_keeper_chat_transcript.ml:1066-1072`). `Never_returned` 는 제외된다.
그런데 운영자 화면에는 같은 도구가 위에서는 `1 never returned:
keeper_analyze_image`, 아래에서는 `still running: keeper_analyze~` 로 나왔다.

조사(PR-0) 결과 **표시 버그로 확정**했다. 근거 세 줄이다.

1. `tool_calls t` 는 `reversed_tool_calls` 전체를 돌려준다. attempt 를 가리는
   필터가 없다(`masc_tui_keeper_chat_transcript.ml:327`).
2. `Runtime_attempt_started` 는 텍스트 buffer 만 비우고 호출은 그대로 둔다.
   주석이 그렇게 적혀 있다 — "Tool evidence stays where it was: the calls
   remain in `[reversed_tool_calls]`"(:1382).
3. `live_tool_call` 에는 attempt 필드가 없다(:84-101). 그래서 `still_running`
   필터가 "지금 attempt 의 것" 을 물을 방법이 없다.

결과: failover 로 버려진 runtime 에서 열린 채 남은 호출이 새 attempt 의 진행
행에 `still running` 으로 계속 잡힌다. `oldest_open_call`(:1021)도 같은 목록을
보므로 `in this call <age>` 역시 버려진 호출의 나이를 말할 수 있다.

증거 보존(2)은 옳다. 그 호출은 trail 에 남아야 한다. 틀린 것은 **집계**다.
trail 은 "무슨 일이 있었나" 를 답하고 진행 행은 "지금 무엇이 열려 있나" 를
답하는데, 지금은 한 목록이 두 질문에 같은 답을 준다.

재현은 `test_a_superseded_attempts_open_call_is_not_still_running` 이 고정한다.

고치는 길 둘이었다. (a) `live_tool_call` 에 attempt 를 실어 `still_running` 에서
현재 attempt 만 센다. (b) `Runtime_attempt_started` 에서 열린 호출을
`Never_returned` 로 닫는다 — 버려진 호출은 실제로 결과를 못 받았으므로 의미가
맞지만, `ended`/`failed` 를 건드리면 trail 표시가 같이 움직인다.

**(a) 로 PR 1 에서 고쳤다.** `attempt` 필드를 추가하고, "지금 열려 있나" 를 묻는
두 곳 — `still_running` 과 `oldest_open_call` — 만 현재 attempt 로 좁혔다. 개수
(`N tools`)와 tool mix 는 턴 전체를 유지한다. 그 둘은 "이 턴이 무엇을 했나" 를
답하고, 거기에는 버려진 attempt 도 포함되기 때문이다. trail 표시는 그대로다.

## 4. PR 절단선

| PR | 범위 | 파일 | 위험 |
|---|---|---|---|
| **0** (완료) | §3.6 조사 — attempt 전환 시 열린 call 의 추적. 버그로 확정 | 없음(조사) | 없음 |
| **1** | 경계를 건드리지 않는 정리: 로스터 기본 숨김 · 토글 키가 한 일을 말하게 · §3.4 중복 제거 · §3.6 집계 수정 · mli 문서 정정 | `types.ml` `masc_tui.ml` `transcript.ml` `message_layout.mli` | 낮음. 행 예산 불변 |
| **1b** | §1.6 에러에 runtime id 와 복구 시각. `persisted_error_reply` 호출부에 runtime id 가 없어 배선이 먼저다 | `server_routes_http_keeper_stream.ml` | 중간. 서버가 내보내는 문구의 계약 |
| **1d** | 버려진 호출만 든 tool 블록이 여전히 "돌는 중" 으로 요약된다. `compact_outcome` 이 열린 호출 하나로 블록 전체를 `Started` 로 올리는데, 이를 attempt 로 가리려면 `tool_activity` 가 attempt 를 실어야 한다 | `transcript.ml` | 중간. 타입 변경이 trail 렌더까지 번진다 |
| **2** | §3.3 계기판 접기 — 상태 행을 1행으로, 펼침 키 | `render.ml` 상태 블록 | 중간. 행 예산 변경 |
| **3** | §3.2 시간축 통합 — promoted·NEXT 를 transcript 로 | `render.ml` `message_layout.ml` | 높음. 스크롤·높이 계산 |
| **4** | §1.7 diff 발견성 — compact 에서 변경 요약 칩 | `render.ml` `chat_diff.ml` | 중간 |

PR 1 은 나머지와 독립이다. PR 2 와 3 은 같은 행 예산을 건드리므로 **2 → 3 순서로
하고 사이에 다른 레이아웃 변경을 넣지 않는다.** 따로 하면 두 번째가 첫 번째를
되돌린다.

`masc_tui_render.ml` 은 19,665 행이다. PR 2·3 전에 이 파일의 분해가 예정되어
있다면 그것을 먼저 한다 — 같은 블록을 두 번 헤집지 않기 위해서다.

## 4.5 `chat-turn-rail-and-side-lanes` 와의 관계

같은 화면을 먼저 본 RFC 가 있다(2026-09-06, Draft). 진단의 한 문장이 겹친다 —
"채팅 화면은 한 턴 안에서 일어난 일과 턴 밖에서 도착한 것을 같은 컬럼에 같은
무게로 쌓는다."

두 RFC 는 **축이 다르고 보완적이다.**

| | 레일 RFC | 이 RFC |
|---|---|---|
| 무엇을 가르나 | 턴 **안**(본선) ↔ 턴 **밖**(측선) | **대화** ↔ **계기판** ↔ **입력** |
| 수단 | 있는 `turn_rail` 에 층을 더한다 (`╭ │ ├ ┤ ╰`) | 영역의 경계와 행 예산 |
| 대상 행 | 사고·도구·스킬·승인·journal·남이 보낸 줄 | promoted·NEXT·Progress·Gate·composer |

레일은 transcript **안쪽** 행들의 위계를 그리고, 이 RFC 는 transcript 와 계기판
**사이**에 없는 경계를 만든다. 한쪽이 다른 쪽을 대신하지 않는다.

**겹치는 자리는 하나다.** §3.2 에서 promoted·NEXT 를 transcript 로 들여보내면
레일이 그 두 행도 그려야 한다 — 아직 확정되지 않은 턴의 시작을 레일이 어떻게
여는지는 레일 RFC 가 정할 문제다. 그래서 **PR 3 은 레일 RFC 의 구현 상태를 보고
순서를 정한다.** 레일이 먼저 들어가면 PR 3 은 레일 어휘를 쓰고, 아니면 PR 3 이
평범한 행으로 넣은 뒤 레일이 나중에 덮는다. 어느 쪽이든 두 번 그리지는 않는다.

PR 1(이 PR)과 PR 2 는 레일이 그리지 않는 영역만 건드리므로 순서와 무관하다.

## 5. 외부 근거 (2026-09-12 확인)

- **고정 영역 + 스크롤 본문 + 하단 바**: htop·tig 의 형태. 패널이 프레임마다
  움직이지 않아야 공간 기억이 생긴다. 지금 composer 는 상태 행 수에 따라 움직인다.
- **색은 위계를 강화하지 만들지 않는다**: 색을 다 뺐을 때 못 쓰면 설계가 깨진 것.
  16색에서 동작해야 한다. §3.5 의 근거.
- **단계적 공개**: footer 필수 키 → 도움말 overlay → 문서. `RFC-tui-operator-ia`
  §5 전이패턴 ④(함대 1줄 → tool 행 → 전체 trace)와 같은 규칙이다.
- **화면의 모든 칸은 자리값을 한다**: `AT THE GATE` 가 대기 0건일 때도 한 행을
  쓰던 것이 여기에 걸린다.

출처: <https://hyperbliss.tech/blog/2026.04.04_terminal-renaissance/>,
<https://github.com/Simon-He95/vue-tui/blob/main/docs/terminal-ui-best-practices.md>

## 6. 하지 않는 것

- **runtime lane 의 재시도 정책**(지적 #10). 계속 실패하는 대상을 계속 고르는
  것이 맞는지는 lane preference 의 문제다. 이 RFC 는 그 실패를 **읽을 수 있게**
  만들 뿐이다. 별도 이슈로 분리한다.
- **좌측 로스터 삭제**. 기본값을 끄되 `Ctrl-B` 는 남긴다. 지우는 판단은 Orca 식
  4상태 칩(`RFC-tui-operator-ia` §5 전이패턴 ③)을 넣은 뒤에 한다.
- **렌더 기반 교체**(ANSI 직접 → Notty 등). `RFC-tui-operator-ia` §7 과 같다.
- **metadata 열 기본값 변경**(지적 #5). `Origin_row` 는 운영자가 `Ctrl-F` 로 켠
  상태다. 다만 `masc_tui_message_layout.mli:199` 는 기본값을 `Origin_bare` 라
  적었고 실제 기본값은 `Origin_inline`(`masc_tui_types.ml:5436`)이다. 문서가
  낡았을 뿐이므로 PR 1 에서 주석만 고친다.
