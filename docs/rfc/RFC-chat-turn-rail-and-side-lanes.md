---
rfc: "chat-turn-rail-and-side-lanes"
title: "턴은 본선, 밖에서 온 것은 측선 — 채팅 화면의 위계를 레일로 그린다"
status: Draft
created: 2026-09-06
updated: 2026-09-06
author: claude
supersedes: []
superseded_by: null
related: ["chat-references-are-recorded-not-guessed", "skill-usage-rollup"]
---

# RFC: 턴은 본선, 밖에서 온 것은 측선

## 0. 결정 요약

채팅 화면은 한 턴 안에서 일어난 일과 턴 밖에서 도착한 것을 같은 컬럼에
같은 무게로 쌓는다. 그래서 turn 경계도, 인과도, 순서도 보이지 않는다.

레일(`turn_rail`)은 이미 있고 옳게 동작한다. 다만 1셀짜리 신호라 10셀
라벨 컬럼에 압도당하고, 턴 아래 한 층밖에 표현하지 못한다.
이 RFC는 새 은유를 발명하지 않고 **있는 레일에 층을 더한다**.

- **본선**: 턴 하나가 `╭`로 열려 `│`로 흐르고 `╰`로 닫힌다. 턴 안의 일
  (사고·도구·스킬·승인·위임)은 `├`로 본선에 매달린다.
- **측선**: journal·broadcast·channel·gate 처럼 턴 밖에서 도착한 것은
  본선을 끊지 않고 `─┥`로 옆에서 합류한다.
- **분기**: 한 `stream_scope` 안의 여러 `block_index`는 프로바이더가 한 번에
  낸 병렬 호출이다. `┬`로 갈라 `┴`로 합친다.

## 1. 문제

### 1.1 레일은 옳게 작동한다 — 다만 너무 조용하다

레일은 살아 있다. `merge_blocks`(`bin/masc_tui_render.ml:9609`)가 병합된
목록에서 각 request 의 첫·마지막 인덱스를 찾아 edge 를 계산하고
`turn_rail` 을 덮어쓴다. 라이브 경로의 `Turn_continues`(`:9464`)는
그때까지 쓰는 임시값이고, 주석이 말한 대로다.

진행 중인 턴을 닫지 않는 것도 의도다.

```ocaml
let closes = closes_at = index
  && not (Option.equal String.equal live_request_id (Some request_id))
```

아직 끝나지 않은 턴에 `╰` 를 그리면 거짓말이 된다.
`test/test_tui_turn_rail.ml` 이 이 셋을 다 검사한다 — 여는 모서리가 첫 행에
남는 것, 닫는 모서리가 마지막 행에 오는 것, 도구 블록의 첫 행이 `├` 로
갈라지고 줄바꿈된 나머지가 `│` 로 이어지는 것.

문제는 레일이 틀린 것이 아니라 **약한 것**이다.

- 레일 예산은 `turn_rail_cells = 2` — 글리프 한 칸에 공백 한 칸.
- 그 옆 `chat_role_label_column = 10` 에 `TOOLS`·`STATUS` 가 대문자로 앉는다.
- 1셀 대 10셀. 위계를 말하는 쪽이 종류를 말하는 쪽에 압도당한다.

비교 대상은 예외 없이 **들여쓰기**로 위계를 낸다. 자식은 부모보다 오른쪽에서
시작하고, 그 거리가 곧 깊이다. masc 는 모든 행이 같은 x 에서 시작하고
1셀만 다르다. 같은 사실을 말하면서 신호 세기가 다르다.

### 1.2 레일이 1층만 표현한다

레일이 답하는 것은 네 가지다 — 턴이 열렸다, 흐른다, 일이 매달렸다, 닫혔다.
답하지 못하는 것이 그보다 많다.

| 질문 | 지금 |
|---|---|
| 이 블록은 몇 개의 호출인가 | Compact 롤업 문장 안에 숫자로만 |
| 그 호출들은 병렬인가 순차인가 | 표현 없음 |
| 얼마나 걸렸는가 | 저장된 스텝의 `duration` 만, Compact 에서는 사라짐 |
| 이 행은 턴 안인가 밖인가 | `chat_row_lane` 은 알지만 화면은 모름 |

턴 아래 한 층이 더 필요하다. 지금은 턴과 블록 사이가 전부다.

### 1.3 레일이 두 질문을 다시 섞었다

`turn_rail_glyph`의 주석은 이렇게 선언한다.

> that alphabet answers "who is talking" and this one answers "which turn is
> this row part of". Folding the second question into the first was the shape
> that failed — a mark that means two things stops meaning either.

그런데 `turn_rail_of`(`:8578`)는 `Turn_continues`일 때 **style로**
`Rail_does`(`├`)와 `Rail_says`(`│`)를 가른다. 레일이 "턴 안 어디"가 아니라
"이 행이 도구냐 말이냐"를 답한다. 경계했던 실패 모양이 반대편에서 재발했다.

### 1.4 라벨 컬럼이 위계를 지운다

`chat_role_label_column = 10` 하나에 keeper 이름·`TOOLS`·`STATUS`·
`THINKING`·`JOURNAL`이 전부 같은 x, 같은 폭으로 정렬된다
(`Message_layout.align_role_label ~column:role_label_column`).
주체와 그 주체가 한 일이 형제가 된다.

`chat_row_lane`(`bin/masc_tui_types.ml:797`)은 이미 세 갈래를 안다.

```ocaml
Lane_turn of request_id | Lane_unowned | Lane_memory
```

`Lane_memory`의 주석은 "its place is beside the turns rather than in one"
이라고 못박는다. 그런데 렌더는 전부 세로로 쌓는다. 타입이 아는 것을
화면이 모른다.

### 1.5 롤업이 상세보다 뒤에 온다

`project_tool_block`의 Compact 경로는 `√ Tools 14 · … · 14 details folded`
한 줄을 만든다. 이 줄은 그 14개가 **끝난 뒤** 형제 행으로 놓인다.
바로 아래 이어지는 `STATUS` 두 줄이 그 14개 중 일부인지 다음 라운드인지
화면만 봐서는 알 수 없다.

### 1.6 요약과 상세가 동시에 보이지 않는다

`tool_projection_mode` 는 두 값뿐이다.

```ocaml
type tool_projection_mode = Compact | Full
```

`Compact` 는 `√ Tools 14 · … · 14 details folded` 한 줄만 내고 호출을 감춘다.
`Full` 은 호출을 다 내고 요약을 없앤다. 몇 개가 무엇으로 끝났는지 보면서
그중 하나를 짚는 상태가 없다.

비교 대상은 예외 없이 둘을 함께 낸다 — `Used 15 tools ⌄` 아래 카드,
`명령 21개 실행함` 아래 목록, `Setting up environment` 아래 스텝.
요약은 헤더고 상세는 그 자식이다. 형제가 아니다.

### 1.7 원문이 화면을 먹는다

`STATUS` 행이 `tool_execute · python3 -c 'import base64;print(base64.b64decode('\''…`
를 그대로 뱉는다. 한 호출의 base64 인자가 화면 절반을 차지한다.
의도를 말하는 자리에 원문이 앉아 있다.

## 2. 지금 있는 것 (재고)

새로 만들 필요가 없는 것부터 센다.

| 재료 | 위치 | 상태 |
|---|---|---|
| 레일 글리프 `╭ │ ├ ╰` | `masc_tui_message_layout.ml:717` | 있음, 부분 미사용 |
| 턴 경계 계산 | `masc_tui_types.ml:831` `mark_turn_edges` | 있음, 히스토리 전용 |
| 레인 3갈래 | `masc_tui_types.ml:797` `chat_row_lane` | 있음, 렌더 미반영 |
| 병렬 판정 재료 | `masc_tui_keeper_chat_live.ml:24` `stream_scope`/`block_index` | 있음, 상관관계에만 사용 |
| 호출 소요시간 | `keeper_chat_transcript.tool_activity.duration` | 저장된 스텝만 |
| SGR 마우스 | `masc_tui.ml:11748`, Ctrl-T 토글 | 있음, Activity 패널만 배선 |
| 접힘 상태 | `reasoning_visibility`/`tool_visibility`/`memory_visibility` | 있음, 레인별로 흩어짐 |

## 3. 없는 것

| 없는 것 | 왜 필요한가 |
|---|---|
| 라이브 턴의 실제 edge | `╭`/`╰`가 그려지려면 |
| 병렬 그룹 타입 | `stream_scope` 동석을 화면 개념으로 올리려면 |
| `DELEGATE` wire 이벤트 | keeper가 keeper에게 맡긴 일이 화면에 없다 |
| `BROADCAST` wire 이벤트 | 지금은 별개 msg_entry로만 도착 |
| `CHANNEL`(connector/gate) wire 이벤트 | 커넥터 왕복과 gate 판정이 턴 옆에 없다 |
| 프로바이더 스트림 지표 | 토큰·속도가 delta에 없다 |
| 채팅 패널 마우스 배선 | 접기/펴기를 클릭으로 하려면 |
| 레인 필터 | 3개 visibility가 레인마다 따로 자란 결과 |

## 4. 설계

### 4.1 두 축

레인은 두 질문에 답한다. 한 글자에 섞지 않는다.

- **축 1 (소속)**: 이 행은 어느 턴의 것인가 — 본선인가 측선인가.
- **축 2 (종류)**: 턴 안이라면 무슨 일인가 — 사고·도구·스킬·승인·병렬·위임.

축 1은 레일이, 축 2는 레인 라벨이 답한다.

### 4.2 화면

```
15:00 ╭ ● rondo          CI 판정을 확인하겠습니다.
      ├─ · THINKING      PR 매치 지점과 CI 로그를 대조 · 4s                    ⌄
   ◆──┥                  JOURNAL   memory revision 4301 · +1 −0 · 138 유지     ⌄
      ├┬ ⇉ PARALLEL 3    2.4s · 직렬 환산 6.1s
      │├─ ✓ keeper_artifact_read    masc_tui_render.ml:14926            0.4s
      │├─ ✓ masc_board_post_get     #33592                              1.4s
      │└─ ✓ Execute                 gh pr checks 33592                  2.4s
      ├┴
   ⇢──┥                  BROADCAST geek-scout → 전체 · "제 오독이었습니다"     ⌄
      ├─ ⏸ APPROVAL      gh api …/jobs/101437813484/logs   대기 12s → 승인됨
   ⇄──┥                  CHANNEL   slack#release-deployment ← connector  ⌄
   ⊘──┥                  GATE      host-gate  cwd 밖 쓰기 거부 · path_scope ⌄
      ├─ ⇥ DELEGATE      code-reviewer ← "fc_kind with 전수 grep"  진행 중 40s
      ├─ ◈ SKILL         ocaml-coding                        전달됨 → 사용됨
      ├─ ■ TOOLS 4       ✓ 2.0s · masc_board_comment 1 · Execute 3       ⌄
15:04 ╰ ● rondo          판독 완료 — 매치 6곳 중 4곳만 수정.
```

### 4.3 어휘 규칙

레인 라벨은 영어, 상태·설명·수치는 한국어. 라벨은 도구 이름·코드 식별자와
같은 철자를 써서 화면에서 본 것을 그대로 grep 할 수 있게 한다.
`phrasing-vocabulary.md` §8과 같은 이유다.

### 4.4 정보 손실

`~`와 `…`로 잘라내는 것을 기본값에서 뺀다. 대신:

- 긴 인자는 **접는다**. 잘라내면 없어지고 접으면 남는다.
- 접힌 것은 개수를 밝힌다 — `⋯ 11개 더`. 몇 개가 숨었는지 모르는 접힘은
  잘라내기와 같다.
- `Full` 모드에서는 어떤 행도 잘리지 않는다. 폭이 모자라면 감싼다.

### 4.5 접기·펴기·필터·마우스

- 접힘은 **행 단위 상태**다. 지금처럼 레인마다 전역 토글 세 개
  (`reasoning`/`tool`/`memory`)로 갈라두지 않는다.
- 전역 토글은 **레인 필터**로 일반화한다. 레인 하나를 끄면 그 레인 행이
  사라지고, 사라진 개수가 헤더에 남는다.
- 마우스: 채팅 패널이 SGR 리포트를 받아 `⌄` 히트 영역에서 접힘을 토글한다.
  Ctrl-T 로 마우스를 놓으면 키보드 경로가 그대로 남는다.

### 4.6 Web Dashboard

같은 위계를 두 surface가 쓴다. 화면 문법(레일·레인·접힘 상태)은 TUI가
정의하고, Dashboard 는 같은 typed projection 을 읽어 자기 방식으로 그린다.
projection 을 각자 다시 만들면 두 화면이 서로 다른 이야기를 하게 된다.

## 5. 증분 계획

각 증분은 그 자체로 머지 가능하고, 앞 증분 없이는 성립하지 않는다.

| # | 범위 | 산출 | 검증 |
|---|---|---|---|
| 1 | 요약을 헤더로, 상세를 자식으로 | 한 블록이 요약 1행 + 상세 N행, 상세는 요약보다 들여씀 | 요약과 상세가 같은 프레임에 |
| 2 | 레일에서 style 분기 제거 | `Rail_does`/`Rail_says` 판정을 style 이 아니라 소속으로 | 같은 style 이 본선/측선 양쪽에 놓여도 레일이 다름 |
| 3 | 측선 도입 | `Lane_memory`/`Lane_unowned` 가 `─┥` 로 합류 | journal 이 턴 사이에 끼어도 턴이 끊기지 않음 |
| 4 | 병렬 그룹 | `stream_scope` 동석을 `┬`/`┴` 로 | 한 scope 3호출 → 분기 1개, 3 scope 3호출 → 분기 0개 |
| 5 | 롤업을 헤더로 | 요약이 상세 **앞** | 접힌 블록의 첫 행이 요약 |
| 6 | 잘라내기 → 접기 | `…` 제거, `⋯ N개 더` | Full 모드에서 잘린 행 0 |
| 7 | 레인 필터 | 토글 3개 → 필터 1개 | 끈 레인의 숨은 개수가 헤더에 |
| 8 | 채팅 패널 마우스 | 클릭 접기/펴기 | 마우스 해제 시 키보드 경로 동일 |
| 9 | wire 이벤트 | DELEGATE/BROADCAST/CHANNEL/STREAM | 각 이벤트에 생산자와 소비자가 동시에 |
| 10 | Dashboard 정렬 | 같은 projection | 두 화면이 같은 턴에 같은 위계 |

증분 9는 렌더 밖(런타임·SSE·저장)으로 범위가 넓어진다. 1–8이 렌더 안에서
끝나므로 9는 그 뒤에 둔다. 없는 데이터를 위해 빈 자리를 먼저 만들지 않는다.

## 6. 비목표

- 색 팔레트 개편. 이 RFC는 배치와 위계만 다룬다.
- 새 은유. `turn_rail` 이 이미 레일이다.
- 레거시 필드·변환기. 화면 상태는 hard cut 으로 바꾼다.

## 7. 열린 질문

1. 측선의 `─┥` 가 좁은 폭(80 컬럼)에서 몇 셀을 먹어도 되는가.
   지금 레일 예산은 `turn_rail_cells = 2` 다.
2. 병렬 그룹의 "직렬 환산" 수치를 낼 근거가 라이브에도 있는가.
   `duration` 은 저장된 스텝에만 있다.
3. Dashboard 가 읽을 projection 의 소유자는 어느 모듈인가.
