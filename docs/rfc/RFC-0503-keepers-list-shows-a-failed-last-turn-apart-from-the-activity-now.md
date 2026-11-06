---
rfc: "0503"
title: "Keepers 목록은 지난 턴의 실패와 지금 하는 일을 따로 보여 준다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude
supersedes: []
superseded_by: null
related: ["tui-operator-workbench", "0418"]
---

# RFC-0503 — Keepers 목록은 지난 턴의 실패와 지금 하는 일을 따로 보여 준다

## 0. 요약

- Keepers 목록의 `! failure` 한 칸이 서로 다른 사실 셋을 같은 글자로 보인다. 마지막으로 끝난 턴이 실패했다(직전). heartbeat 가 실패했다(직전). 열린 턴에서 시도 하나가 실패했다(지금). 앞의 둘은 서버가 `Health_failing` 하나로 합쳐 보낸다.
- 두 값을 `||` 로 묶은 `failed` 가 살아 있는 활동보다 먼저 검사된다(`bin/masc_tui_keeper_list_model.ml:198-206`). 실패 중인 Keeper 가 probe 턴을 돌려도 행에는 `failure` 만 남는다.
- 11-06 01:26 UTC 한 시점에 40행 중 15행이 failing 이었다. 서버가 주는 원인 글자는 15행 모두 `provider` 다. 턴 영수증(receipt)의 typed 값으로 보면 종료 원인이 5묶음으로 갈린다.
- 제안: 행을 `지금`(활동)과 `직전`(마지막으로 끝난 턴이나 heartbeat 의 실패)으로 나눈다. `Failure` variant 를 지우고 실패 행은 `Failing` 묶음으로 모은다. 서버는 바꾸지 않는다.
- 빨강은 운영자가 해야 하는 `Held_call` 에만 남긴다. 실패 표지는 경고색이다.
- 서버가 말하지 않는 값은 지어내지 않고 비운다. 그런 값은 서버 후속 후보(§6)로만 적는다.

## 1. 지금

### 1.1 한 칸이 세 뜻을 낸다

`primary_activity_of_row` 의 앞부분이다(`bin/masc_tui_keeper_list_model.ml:198-207`).

```ocaml
let failed =
  health = Some Masc.Tui_decode.Health_failing
  || activity = Some Masc.Tui_decode.Keeper_activity_attempt_failed
in
if Option.is_some row.approval || waiting_has_source Waiting_source_hitl_pending items then
  Held_call
else if row.open_questions > 0 then Question
else if waiting_has_source Waiting_source_operator_pending_confirm items then Confirmation
else if failed then Failure
else if row.reading.Masc_tui_keeper_control.paused then Paused
```

`failed` 는 두 값을 묶고, 앞의 값은 다시 둘로 갈린다. 서버는 `heartbeat_healthy` 와 `turn_healthy` 중 하나만 거짓이어도 phase 를 `Failing` 으로 정한다(`lib/keeper_registry/keeper_state_machine.ml:61-64`).

| 값 | 뜻 | 되돌아오는 때 |
| --- | --- | --- |
| `Health_failing` ← `turn_healthy = false` | 마지막으로 끝난 턴이 실패했다(`keeper_state_machine.ml:84-87`) | 성공한 턴(`:83`) |
| `Health_failing` ← `heartbeat_healthy = false` | heartbeat 가 실패했다(`:76-82`) | heartbeat 성공(`:75`) |
| `Keeper_activity_attempt_failed` | 열린 턴에서 provider 시도 하나가 실패했다. 턴은 아직 열려 있다. `row.turn` 이 `Keeper_turn_running` 이고 preview 가 `Failed` 일 때만 나온다(`lib/tui_decode.ml:4876-4882`) | 턴이 닫히거나 preview 가 바뀔 때 |

목록이 받는 `Health_failing` 은 앞의 둘 중 무엇인지 말하지 않는다. 가장 최근 실패의 종류는 `kr_last_failure.kf_cause` 가 말한다. `heartbeat` `turn` `provider` 등 8갈래이고 서버가 정한다(`lib/keeper/keeper_tool_surface_ops.ml:292-300`). 읽기 A 의 15행은 모두 `provider` 였다. 두 조건을 따로 담은 `kl_conditions`(`lib/tui_decode.mli:872-884`)는 이미 디코딩되지만 지금은 상세 창만 쓴다(`bin/masc_tui_render_keepers.ml:396-408`).

세 값은 화면에서 네 군데가 겹친다.

| 겹치는 것 | 위치 | 같이 쓰는 것 |
| --- | --- | --- |
| 단어 `failure` | `bin/masc_tui_render_keepers.ml:157` | 없음 |
| 글리프 `!` | `bin/masc_tui_keeper_mark.ml:22` | `Held_call` |
| 색 `Theme.bad` | `bin/masc_tui_render_keepers.ml:175` | `Held_call` |
| 묶음 `Attention` | `bin/masc_tui_keeper_list_model.ml:252` | `Held_call` `Question` `Confirmation` |

같은 함수의 `Some Keeper_activity_attempt_failed -> Failure`(`:230`)는 실행되지 않는다. `failed` 가 그 값을 먼저 가져간다.

### 1.2 한 시점의 실측

읽은 방법과 한계는 [근거 기록](../evidence/research/2026-11-06-keepers-list-past-now-next/README.md)에 있다. 한 워크스페이스의 한 시점이라 일반화하지 않는다. TUI 는 실행하지 않았다.

| 읽은 것 | 값 |
| --- | --- |
| 행(11-06 01:26:31 UTC, 읽기 A) | 40행. failing 15, offline 18, healthy 7 |
| 서버의 `last_failure.cause`(닫힌 8갈래) | `provider` 15/15 |
| 영수증 종료 후보의 원인(typed) | 5묶음: 7 · 4 · 2 · 1 · 1 |
| 종료 후보 원인의 `retry_after` | 15/15 가 비어 있다 |
| `kr_next_action` | `probe` 15/15 |
| 12시간(30분 24칸) 중 실패 턴이 있는 칸 수 | 21~24칸 3행, 9칸 1행, 2~5칸 10행, 0칸 1행 |
| 12.7분 뒤(읽기 B) | 15행 중 8행이 failing 을 벗었다. 그 8행은 `last_failure` 를 더 갖지 않는다(0/8) |

`Held_call` `Question` `Confirmation` 에 걸리지 않은 failing 행은 모두 같은 `! failure` 로 그려진다. 읽기 A 에서는 이 셋을 따로 세지 않았다.

- 서버의 원인 글자로는 15행이 한 칸이다. 영수증의 typed 값으로는 5묶음이다.
- 12시간 중 21칸 이상 실패한 행과 2~5칸 실패한 행이 같은 글자를 쓴다.
- 복구하면 `last_failure` 가 지워져서, 목록은 "방금 복구했다"를 알 길이 없다.

### 1.3 지금 있는 문장

`keeper_failure_context`(`bin/masc_tui_render_keepers.ml:99-110`)가 failing 행의 RUNTIME 칸을 `<현재 활동> · last failed · <원인> · <나이>` 한 문장으로 채운다(`:112-114`). RUNTIME 칸이 없는 폭에서는 DETAIL 맨 앞에 붙는다(`bin/masc_tui_render_schedule.ml:294`). 원인은 위의 8갈래 단어라서 15행이 같은 단어를 되풀이한다.

더 구체적인 값은 이미 디코딩돼 있다. `kr_runtime_lane_observation`(`lib/tui_decode.mli:780`)은 마지막 영수증의 시도 목록과 종료 후보(런타임 id, 원인)를 담는다. 지금은 상세 창만 이를 그린다(`bin/masc_tui_render_keepers.ml:1784-1846`).

상세 창은 이 값을 별도 읽기로 다룬다. 성공한 폴백도 앞선 거절을 영수증에 남기기 때문이다(`:1782-1783`). 영수증의 증거는 그 영수증에만 묶인다(`lib/keeper/keeper_execution_receipt.mli:248-249`).

### 1.4 `Detailed` 레이아웃은 이미 두 줄이다

`Detailed` 의 행 높이는 2다(`bin/masc_tui_render_keepers.ml:818`). 둘째 줄은 `keeper_secondary_row_content`(`:338`)가 `keeper_detail_text` 로 채운다(`:921`). 두 줄 카드는 새 틀이 아니다. 이 RFC 는 첫 줄을 바꾼다. 둘째 줄은 선택 층(L5)에서 다룬다.

### 1.5 목록이 답해야 하는 질문과 값의 출처

| 운영자 질문 | 값 | 출처 | 1단계 |
| --- | --- | --- | --- |
| 지금 실패하고 있나, 지난 턴이 실패했나 | `Keeper_activity_attempt_failed` / `Health_failing` | 디코딩됨 | 된다 |
| 턴 때문인가, heartbeat 때문인가 | `kr_last_failure.kf_cause`(가장 최근 실패 하나), `kl_conditions`(두 조건) | `kf_cause` 는 행에 있다. `kl_conditions` 는 디코딩됐지만 행에는 없다 | 된다 |
| 지금 무엇을 하나 | `row.turn` → `keeper_current_activity_of_turn` | 디코딩됨 | 된다 |
| 마지막 턴은 언제 끝났나 | `kf_at_unix`, 영수증의 `receipt_ended_at` | 디코딩됨 | 된다 |
| 왜, 어디서 끝났나 | `terminal.runtime_id`, `terminal.failure.cause`, 시도마다 `api_candidate_fault` | 디코딩됨. 상세 창만 그린다 | 된다 |
| 몇 번 시도했나 | `evidence.failures` 의 길이 | 디코딩됨 | 된다 |
| 다음이 있나, 언제인가 | `kwi_due_at`(`lib/tui_decode.mli:1382`), `Waiting_source_runtime_quota_spent`, `Provider_rate_limited.retry_after` | 디코딩됨. `retry_after` 는 15/15 가 비어 있다 | 서버가 말한 값만 |
| 언제부터 실패였나, 방금 복구했나, 최근 12시간은 어땠나 | 최근 턴 결과, 실패 시작, 복구 시각 | 서버가 내지 않는다 | 안 된다(§6) |
| 사람이 해야 하나 | 닫힌 판정 값 | 서버가 7갈래를 `unknown_runtime_blocker` 로 모은다(#43018) | 안 된다(§6) |

`kr_next_action` 은 행마다 다음을 가르지 못한다. failing 이면 항상 `Probe` 다(`lib/keeper/keeper_status_runtime.ml:297`).

## 2. 제안

### 2.1 행의 읽기를 둘로 나눈다

`Failure` 를 지우고 `지금` 과 `직전` 을 서로 가리지 않는 두 값으로 둔다.

```ocaml
(* 지금: 이 순간 Keeper 가 하는 일. Failure 가 빠지고 Attempt_failed 가 들어온다. *)
type activity =
  | Held_call | Question | Confirmation
  | Attempt_failed            (* 열린 턴에서 시도 하나가 실패했다 *)
  | Preparing | Streaming | Running | Async_working of int | Deferred
  | Tool_waiting | Model_waiting | Delegate_result | Verifying | External_waiting
  | Idle | Paused | Offline | Unknown

(* 직전: Keeper 가 failing 인 까닭이 되는 마지막 실패. Health_failing 일 때만 Trail_failed 다. *)
type trail =
  | Trail_sound
  | Trail_failed of
      { ended_at : float option
      ; last : Masc.Tui_decode.keeper_failure_cause option  (* kr_last_failure.kf_cause *)
      ; walk : walk }

type walk =
  | Walk_ended of { runtime_id : string; cause : cause_group; tried : int }
  | Walk_no_terminal of { tried : int }   (* Terminal_not_observed *)
  | Walk_not_captured                      (* Runtime_lane_not_observed *)
  | Walk_unreadable                        (* Runtime_lane_unreadable *)
  | Walk_absent                            (* kr_runtime_lane_observation = None *)
  | Walk_not_applicable                    (* 가장 최근 실패가 턴의 실패가 아니다: heartbeat 등 *)
```

- `primary_activity_of_row` 에서 `failed` 분기를 지운다. failing 행도 `Paused` 와 살아 있는 활동 갈래를 그대로 지난다. `Offline` 은 health 가 한 값이라 failing 과 겹치지 않는다. 끝의 `Some Keeper_activity_attempt_failed` 갈래(`:230`)가 그때부터 `Attempt_failed` 를 만든다. `Held_call` `Question` `Confirmation` 이 앞서는 순서는 그대로다.
- `trail_of_row` 는 `Health_failing` 일 때만 `Trail_failed` 를 준다. 건강한 행은 영수증에 거절이 남아 있어도 `Trail_sound` 다.
- `walk` 는 가장 최근 실패가 턴의 실패일 때만 만든다. 어느 `kf_cause` 가 턴의 실패인지는 L3 가 `lib/keeper/keeper_registry_types_failure.ml` 의 정의를 읽고 와일드카드 없는 `match` 로 정한다. heartbeat 실패는 `Walk_not_applicable` 이다. 마지막 영수증은 성공한 폴백 턴의 거절을 담을 수 있어서(`bin/masc_tui_render_keepers.ml:1782-1783`), heartbeat 실패 옆에 그 기록을 붙이면 원인처럼 읽힌다.
- `cause_group` 은 닫힌 variant 다. `terminal.failure.cause` 를 와일드카드 없는 `match` 로 옮겨 만든다. `Keeper_request_failure.cause` 의 생성자는 22개다(`lib/keeper_runtime/keeper_request_failure.mli:54`). 문자열은 읽지 않는다. 생성자가 늘면 빌드가 깨진다. 시도마다 달린 `api_candidate_fault`(닫힌 값)를 쓸지는 L3 가 정한다.
- 묶음의 수와 이름은 L3 에서 생성자 하나씩 문서 주석을 읽고 정한다. 기준은 하나다. 운영자가 할 행동이 다르면 가르고, 같으면 합친다. 대응표는 L3 PR 에 싣고 리뷰는 그 표로 한다.
- 영수증이 건강 판정과 같은 턴이라는 보장은 서버가 하지 않는다. 그래서 `Walk_ended` 의 값은 영수증 한 장에서만 가져온다. 서로 다른 출처의 조각을 한 문장에 섞지 않는다(D3).

### 2.2 한 줄에 놓는 순서

칸을 새로 만들지 않고 지금 있는 칸을 쓴다. 칸 너비는 `bin/masc_tui_render_schedule.ml:142-154` 가 정한다.

| 칸 | 담는 것 | 지금과 다른 점 |
| --- | --- | --- |
| NOW | `activity` 의 글리프와 단어 | failing 행도 `failure` 대신 살아 있는 활동을 보인다 |
| AGE | `last_activity_at`(마지막으로 움직인 시각) | 그대로. 열린 턴이 있으면 그 턴의 마지막 움직임이고, 없으면 마지막으로 기록된 턴과 대기 시작 중 늦은 쪽이다(`bin/masc_tui_types.ml:12623-12633`) |
| 직전 | `◂ <나이> · <원인 묶음> · <끝낸 런타임> · <시도 수>` | `keeper_failure_context` 를 이 문장으로 바꾼다. 건강이 failing 인 행에만 있다. 자리는 지금 문장과 같다 |
| 다음 | `▸ <상대 시각>` | 서버가 시각이나 사유를 말한 행에만 붙는다. 없으면 만들지 않는다 |

- heartbeat 실패 행은 `◂ <나이> · heartbeat` 만 보인다. 런타임과 시도 수는 턴에만 있다.
- 값이 없는 조각은 자리를 비우지 않고 문장에서 뺀다. 영수증이 없으면 상세 창이 쓰는 말(`no receipt`, `candidate walk was not captured`)을 쓴다. 문구는 L3 에서 상세 창과 맞춘다.
- `다음` 은 `kwi_due_at` 이 있는 대기, `Waiting_source_runtime_quota_spent`, `retry_after` 가 `Some` 인 한도에서만 나온다. `kr_next_action` 으로 행마다 `probe` 를 쓰지 않는다. 같은 단어가 줄마다 되풀이된다.
- 한 줄 안에서 왼쪽은 지금, 가운데는 직전, 오른쪽은 다음이다.
- 열린 턴이 없는 failing 행은 마지막으로 기록된 턴이 곧 실패라서(`bin/masc_tui_keeper_mark.ml:61-65` 주석) AGE 와 `◂ <나이>` 가 비슷한 시각을 가리킨다. 열린 턴이 있는 행은 AGE 가 그 턴을 따라가서 둘이 다른 시각이 된다. 같은 나이가 두 번 나오는 모양이 읽기에 거슬리는지는 L4 캡처에서 본다.
- 이 표는 정보의 순서만 정한다. 칸 폭별 모양은 L4 의 80·120·200칸 캡처로 확인한다. 시각 모형은 시안 HTML 에 있다. 브라우저 모형이라 TUI 의 칸 폭과 다르다.

### 2.3 색

| 요소 | 지금 | 제안 |
| --- | --- | --- |
| `Held_call`(운영자 승인 대기) | `Theme.bad` | `Theme.bad` |
| `Failure` | `Theme.bad` | 없어진다 |
| `Attempt_failed` | `Failure` 로 `Theme.bad` | `Theme.warn` |
| 직전 칸 `◂ …` | `Theme.recede` | `Theme.warn` |
| `Failing` 묶음 제목 | 없음 | `Theme.warn` |
| `Question` `Confirmation` | `Theme.warn` | 그대로 |

- 빨강은 사람이 지금 결정해야 하는 것에만 쓴다. 그 위치를 `Held_call` 이 지킨다.
- `Question` `Confirmation` 과 같은 경고색이 된다. 이 셋은 글리프(`?` `◇`)와 묶음(`Attention`)으로 가른다. 실패는 `◂` 와 `Failing` 묶음이다.
- 색이 없어도 갈려야 한다. 실패 표지는 색이 아니라 글리프 `◂` 와 단어로 있다. NOW 칸의 `!` 는 `Held_call` 에만 남기고, `Attempt_failed` 의 글리프는 L4 캡처에서 정한다.
- `docs/design/tui/LAYOUT-LANGUAGE.md:43-44` 는 더 조용한 표현이 실패나 운영자가 해야 할 결정을 가리면 안 된다고 정한다. 실패 표지는 흐려지지 않고 `Held_call` 과 다른 색으로 남는다.

### 2.4 묶음과 정렬

```ocaml
type attention = Attention | Failing | Active | Waiting | Inactive | Unobserved
```

- `Attention` 은 `Held_call` `Question` `Confirmation` 만 모은다. 사람이 해야 하는 일이다.
- `Failing` 은 `trail` 이 `Trail_failed` 이거나 `activity` 가 `Attempt_failed` 인 행이다. 위 셋이 아니면 이 묶음이다. 일시 정지(`Paused`)한 failing 행도 같은 규칙을 따른다.
- 묶음 순서는 `Attention` → `Failing` → `Active` → `Waiting` → `Inactive` → `Unobserved` 다. `Priority` 정렬이 이 순서를 따른다.
- `group_counts` 는 5개 값 튜플에서 이름 있는 필드의 레코드로 바꾼다. 호출처는 `bin/masc_tui_render_keepers.ml:506,559` 두 곳과 시험 한 줄(`test/test_tui_keeper_list_model.ml:372`)이다.
- `Activity` 정렬은 지금 `Failure` 에 순위 3을 준다. `Attempt_failed` 가 그 순위를 이어받는다. failing 행은 이제 지금 하는 일의 순위를 따른다. 위로 모으는 일은 `Priority` 정렬과 `Grouped` 가 맡는다(D5).

## 3. 바뀌는 것

| 파일 | 변화 | 층 |
| --- | --- | --- |
| `bin/masc_tui_keeper_list_model.ml(i)` | `Failure` → `Attempt_failed`. `failed` 분기를 지운다. `:230` 의 갈래는 `Attempt_failed` 를 만드는 유일한 갈래로 남긴다(와일드카드가 없어 지우면 비망라가 된다). `attention` 에 `Failing`. `group_of_activity`(:251)는 활동 하나만 받는데 `Failing` 은 건강도 읽어야 해서, 묶음은 `group_of_row` 와 `rank`(:258, :299)가 정한다. `group_counts` 레코드 | L2 |
| `bin/masc_tui_keeper_trail.ml(i)` (새 파일) | `trail` `walk` `cause_group` 과 이를 만드는 순수 함수. 기존 모델 파일은 359줄이라 새 코드를 거기에 넣지 않는다. `bin/dune` 에 새 `library` stanza 를 두고(`masc` `masc.masc_types`), 모델 stanza 의 `libraries` 에 더한다(`bin/dune:1559-1563`). `dune-project:37` 이 `implicit_transitive_deps false` 라서 `masc-tui` 실행 파일의 `libraries`(`bin/dune:2714` 이하)에도 이름을 적어야 한다. `masc_tui_render_keepers` 는 라이브러리가 아니라 그 실행 파일의 모듈이다(`bin/dune:2708`) | L2 타입, L3 내용 |
| `bin/masc_tui_keeper_mark.ml` | `activity_glyph` 의 `Failure` 갈래를 지우고 `Attempt_failed` 를 더한다 | L2, L4 |
| `bin/masc_tui_render_keepers.ml` | 단어 · 스타일 · 묶음 제목 · `keeper_failure_context` 를 새 값으로 바꾼다. 실패 문장 폭에 묶인 값 둘도 새 문장에 맞춘다(아래) | L2 ~ L4 |
| `test/test_tui_keeper_list_model.ml` | 기존 시험 둘이 바뀐다(아래). 결정 시험을 더한다(§7) | L2, L3 |

동작이 바뀌는 곳이 셋이다.

1. failing 행의 NOW 칸이 `row.turn` 의 활동을 보인다. 활동을 읽지 못하면 대기 목록이 말하는 상태를 보이고, 그것도 없으면 `unknown` 이다.
2. `Activity` 정렬에서 failing 행이 위에 모이지 않는다.
3. `failure` 라는 단어가 화면에서 없어진다.

기존 시험 둘이 바뀐다. 둘 다 `Failing` 묶음이 `Attention` 에서 갈라진 결과다.

- 순서 시험(`test/test_tui_keeper_list_model.ml:139-158`)은 failing 행 `failure` 를 `Attention` 묶음 안에 둔다(:150, :157). 세 행의 `last_activity_at` 이 같아 이름순으로 `failure` `held` `question` 이 나온다. `Failing` 이 `Attention` 다음 묶음이 되면 `failure` 는 `held` `question` 뒤로 간다. 기대 목록만 고치고 새 순서 단언은 더하지 않는다(`docs/constitution.xml:354`).
- `group_counts` 시험(:363-372)은 5개 값 튜플 `(1, 1, 1, 0, 1)` 을 비교한다. 레코드로 바꾸면 비교 모양이 바뀐다.

실패 문장의 폭에 묶인 값이 둘 있다.

- `bin/masc_tui_render_keepers.ml:747-751` 은 failing 행이 하나라도 있으면 RUNTIME 칸 폭의 상한을 리터럴 `60` 으로 올린다. 실패 문장이 그 칸 안에 그려지기 때문이다(:323).
- `has_failing_keeper`(:728-735)는 그때 RUNTIME 칸이 이름 칸보다 먼저 남는 폭을 받게 한다(`~prioritize_runtime` :763, `bin/masc_tui_render_schedule.ml:219`).

새 직전 문장은 길이가 다르다. L3 가 최대 길이를 재서 `60` 을 이름 있는 상수로 바꾼다.

옛 칸의 흔적이 같은 파일에 남아 있다.

- 도움말의 `Keeper columns`(`bin/masc_tui_keeper_mark.ml:111-119`, 생성 문서 `docs/guides/TUI-KEYS.md:839-843`)는 `HEALTH` 와 `TURN` 칸을 설명한다. 목록 머리글에는 그런 칸이 없고 `NOW` 와 `AGE` 가 있다(`bin/masc_tui_render_keepers.ml:257-274`). L4 에서 `NOW` `AGE` 직전 칸을 설명하는 글로 바꾸고 생성 문서를 다시 만든다.
- `open_turn` 과 `turn_clock`(`bin/masc_tui_keeper_mark.ml:49-73`)은 그 옛 칸의 값이다. 부르는 곳은 시험(`test/test_tui_keeper_mark.ml`)뿐이다. `Worked_while_failing` 은 이 RFC 의 `trail` 과 같은 사실을 다른 이름으로 적는다. L2 에서 시험과 함께 지운다(D7).

## 4. 하지 않는 것

- 서버 코드, 와이어 필드, 영수증 형식을 바꾸지 않는다.
- 원인을 문자열로 가르지 않는다. `runtime_blocker_summary` 를 읽지 않는다.
- 서버가 말하지 않은 시각 · 횟수 · 상태 이름을 만들지 않는다. "만성" "회복 중" "다음 시도 16:06" 같은 말을 쓰지 않는다.
- `Health_failing` 의 뜻(턴이나 heartbeat 가 건강하지 않다)을 바꾸지 않는다.
- 화면 문구 · 배치 · 행 순서를 확인하는 시험을 만들지 않는다(`docs/constitution.xml:354-355`).
- 새 차트 부품을 만들지 않는다. 12시간 맥박은 서버 값이 생긴 뒤 워크벤치 RFC §6.3 의 부품으로 그린다.
- Memory · Schedule 열 합치기, 오래된 기억(stale)과 갱신(renew) 표시, 월드 전체 기억은 이 RFC 밖이다. 나중에 붙일 때 나이는 표시 전용이다(RFC-0418, `lib/keeper/keeper_memory_os_types.mli:333-334`).

## 5. 층

| 층 | 내용 | 확인 |
| --- | --- | --- |
| L1 | 이 RFC | 운영자가 받아들인다 |
| L2 | `activity` / `trail` 분리, `Failing` 묶음, `Failure` 삭제, 안 쓰는 `open_turn` `turn_clock` 삭제 | 결정 시험, §7 의 `rg` 기준선이 0 으로 |
| L3 | `cause_group`, `walk`, 직전 문장 | 생성자 대응표 리뷰, 15행 변환 계산표 |
| L4 | 색, 묶음 제목, 글리프, 도움말의 칸 설명 | 80 · 120 · 200칸 캡처, 색을 지운 캡처, 질문 6개 표 |
| L5(선택) | `Detailed` 둘째 줄에 시도 목록, `runtime_path_rest` 디코딩 | 캡처 |

- 층마다 `gh stack` 의 한 PR 이고 Draft 다. 한 PR 은 토큰 2만 이하로 둔다.
- L2 부터는 이 RFC 를 운영자가 받아들인 뒤, 따로 승인받고 시작한다.

## 6. 서버 후속(2단계)

후보만 적는다. 합의 전에는 이슈를 열지 않는다.

1. 최근 턴 결과 N개: 맥박과 "간헐 실패 / 계속 실패"의 구분. 지금은 결정 로그를 직접 읽어야 한다.
2. 실패 시작 시각: 읽기 C 에서 `failing_since` 가 채워진 행은 0/15 였다. 그중 8행은 이미 복구한 뒤였다.
3. 복구 시각: 복구하면 `last_failure` 가 지워진다(0/8).
4. "사람이 해야 하나"의 닫힌 값: #43018. 서버가 7갈래를 `Alert` / `unknown_runtime_blocker` 로 모은다(`lib/keeper/keeper_runtime_trust_snapshot_core.ml:71`).
5. 제공자가 말한 해제 시각: 서버는 날짜 없는 한도의 해제 시각을 일부러 내지 않는다(`lib/keeper/keeper_tool_surface_ops.ml:308-310`).

## 7. 확인 방법

화면 시험은 만들지 않는다. 증거는 캡처와 계산표다.

**결정 시험(L2, L3)**: failing 행의 `activity` 가 `Failure` 가 아니라 살아 있는 활동이다. `Held_call` 이 failing 보다 앞선다. failing + `Idle` 은 `Failing` 이고 failing + `Question` 은 `Attention` 이다. `Attempt_failed` 는 `Failing` 이다. `trail_of_row` 는 `Health_failing` 일 때만 `Trail_failed` 를 준다. 지금 시험은 `Failure` 라는 이름을 단언하지 않는다. 다만 순서 시험과 `group_counts` 시험이 L2 에서 바뀐다(§3).

**기준선**(main `e1001bccf3a`):

```sh
rg -c '\bFailure\b' bin/masc_tui_keeper_list_model.ml bin/masc_tui_keeper_list_model.mli bin/masc_tui_keeper_mark.ml   # list_model.ml 6, list_model.mli 1, keeper_mark.ml 1
rg -n '\bFailure\b' bin/masc_tui_render_keepers.ml                                       # 4줄. 1512 줄은 화면 제목 문자열
rg -n 'Keeper_activity_attempt_failed -> Failure' bin/masc_tui_keeper_list_model.ml      # 1줄. L2 뒤에는 이 갈래가 Attempt_failed 를 만든다
```

L2 가 끝나면 첫째와 셋째는 출력이 없고, 둘째는 제목 문자열 한 줄만 남는다.

**운영자 질문 6개**: 각 질문에 키를 몇 번 눌러 답하는지 잰다. 측정값은 L4 PR 본문에 둔다.

| 질문 | 지금 | 목표 |
| --- | --- | --- |
| 지금 실패하는가, 지난 턴이 실패했는가 | 같은 `! failure` 라 가를 수 없다 | 0키 |
| 지금 무엇을 하는가 | failing 행은 활동 대신 `failure` | 0키 |
| 마지막 턴은 언제 끝났는가 | RUNTIME 칸이 켜진 폭에서 0키 | 0키 |
| 왜 끝났는가 | 8갈래 글자(15/15 가 `provider`), 자세한 값은 상세 창 | 묶음 단어 0키, 자세한 값은 상세 창 |
| 다음이 있는가 | 배지가 있으면 0키, 시각은 상세 | 서버가 말한 값만 0키 |
| 사람이 해야 하는가 | `Attention` 안에서 failing 과 섞인다 | `Attention` 은 사람이 해야 하는 행만. 서버 값이 없는 판정은 `모름` |

**캡처(L4)**: 80 · 120 · 200칸, 색 있음과 색을 지움. 입력은 읽기 A 의 모양을 이름 없이 옮긴 합성 행이다. 같은 단어가 줄마다 되풀이되지 않는지, `Held_call` 이 `Failing` 과 색 없이도 갈리는지 본다.

## 8. 정할 것

| # | 질문 | 제안 |
| --- | --- | --- |
| D1 | 실패 표지의 색 | `Theme.warn`. `Question` `Confirmation` 과 같은 색이지만 글리프와 묶음으로 가른다. 더 흐린 색은 실패를 가린다(LAYOUT-LANGUAGE) |
| D2 | `Failing` 을 따로 묶을까 | 따로 묶는다. 대안은 지금처럼 `Attention` 안이다. 따로 두면 `Attention` 에 사람이 해야 하는 행만 남는다. 대신 묶음이 5개에서 6개가 되고 `group_counts` 의 형태가 바뀐다 |
| D3 | 직전 나이의 기준 시각 | 턴의 실패이고 영수증이 있으면 영수증 시각(`Masc_domain.parse_iso8601_opt` 로 읽는다. 대시보드가 이미 쓴다, `lib/dashboard/dashboard_goals_types_builder.ml:197`). 그 밖(영수증 없음, heartbeat 실패)은 `kf_at_unix` 와 8갈래 원인 단어다. 한 문장에는 한 출처만 쓴다. L3 가 15행에서 두 시각의 차이를 재서 표로 남긴다 |
| D4 | `retry_after` 를 보일까 | `Some` 일 때만 서버가 말한 값 그대로 `▸` 로 보인다. `None` 이면 아무것도 쓰지 않는다. 읽기 A 는 15/15 가 `None` 이라 지금은 거의 안 보인다 |
| D5 | `Activity` 정렬에서 failing 행이 위에 모이지 않는 것을 받아들일까 | 받아들인다. 모으는 일은 `Priority` 정렬과 `Grouped` 가 맡는다 |
| D6 | `Detailed` 둘째 줄에 시도 목록을 둘까 | L5 로 미룬다. 1단계는 첫 줄만 바꾼다 |
| D7 | 옛 `HEALTH` `TURN` 칸의 값(`open_turn` `turn_clock`)을 L2 에서 같이 지울까 | 지운다. 시험만 부르고, 남기면 같은 사실을 두 이름으로 적는다 |

## 9. 참고

- 연구 문서: [`docs/research/2026-11-06-keepers-list-past-now-next.md`](../research/2026-11-06-keepers-list-past-now-next.md)
- 근거 기록: [`docs/evidence/research/2026-11-06-keepers-list-past-now-next/README.md`](../evidence/research/2026-11-06-keepers-list-past-now-next/README.md)
- 시안(설계 보조 자료, 실행되는 TUI 가 아니다): [`docs/research/2026-11-06-keepers-list-past-now-next-preview.html`](../research/2026-11-06-keepers-list-past-now-next-preview.html)
- 워크벤치 RFC §4.2 와 S3-2 도 `Failing` 묶음을 그린다. 이 RFC 는 그중 서버 변경 없이 되는 부분만 좁혀서 낸다. §4.2 의 예시 값(`다음 시도 16:06:51`, `28회 연속`)은 서버가 내지 않는다. 이 RFC 를 받아들이면 §4.2 가 이 문서를 가리키게 고친다.
