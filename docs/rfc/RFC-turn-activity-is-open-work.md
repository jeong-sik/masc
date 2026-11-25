---
rfc: "turn-activity-is-open-work"
title: "턴 미리보기의 활동은 마지막 사건이 아니라 지금 열려 있는 일이다"
status: Accepted
created: 2026-11-25
updated: 2026-11-25
author: claude
supersedes: []
superseded_by: null
related: ["0503", "0486"]
---

# RFC turn-activity-is-open-work: 턴 미리보기의 활동은 마지막 사건이 아니라 지금 열려 있는 일이다

- 상태: **승인(2026-11-25).** 운영자가 추천안대로 하라고 했다(「추천대로 해주십쇼. 제대로 근본 수선이 필요합니더」). §6의 세 가지는 거기에 적은 값으로 정했다.
- 운영자가 11-25에 TUI에서 겪은 일에서 나왔다. 「얘가 답변을 하는 중인지, 추론을 하는 중인지, 도구를 쓰고 기다리면서 나에게 말하는 건지 전혀 감이 안 온다」.
- 설계 판단을 Codex(`gpt-6-astra`, effort high)와 함께 봤다. 둘 다 코드만 읽었다. 실행 검증은 §8에서 한다.
- 코드 좌표는 `origin/main` `37be9897456`에서 읽었다.

## 0. 요약

- 키퍼가 스스로 돌리는 턴은 TUI가 실시간 스트림을 받지 않는다. TUI와 대시보드가 보는 것은 서버의 턴 미리보기 하나다.
- 미리보기의 `activity`는 마지막으로 관측한 사건의 종류이다. 시작하고 아직 끝나지 않은 일을 나타내지 못한다.
- 11-25 17:43:29부터 17:43:58까지 TUI 상태 줄은 `응답 수신` 그대로였다. 서버 로그에는 같은 30초에 도구 `Execute`가 3번 더 실행됐다.
- 이 RFC는 다섯 가지를 정한다.
  1. 미리보기가 「지금 열려 있는 일」 목록을 싣는다(D1).
  2. 일이 열리고 닫히는 때는 실행 수명에서 온다(D2).
  3. `activity`는 그 목록에서 계산한다(D3). 옆에 따로 갱신하는 값을 두지 않는다.
  4. TUI 상태 줄은 그 목록을 그대로 보여 준다(D5).
  5. 연결이 끊겼으면 「대기 중」으로 추정하지 않는다(D6).

## 1. 지금 값으로는 안 되는 이유

### 1.1 관찰

- 두 번째 TUI 인스턴스로 `code-reviewer-sister`의 자율 턴을 2초 간격으로 받아 적었다.
- 상태 줄은 `◐ 최근 확인 · 응답 수신 · 최근 도구: Execute · 자율`이었다. 30초 동안 채팅 창의 글자도 상태 줄도 바뀌지 않았다.
- 서버 시스템 로그(`.masc/logs/system_log_2026-11-25.jsonl`)의 같은 키퍼: 08:43:20~29 UTC에 `tool_call tool=Execute` 2번, 08:43:40~49에 1번, 08:43:50~59에 2번, 08:44:00~09에 턴이 끝났다.
- 실제는 도구를 번갈아 돌리는 중이었고, 화면은 「응답 받는 중」이었다.
- 표본은 이 하나다. 빈도는 재지 않았다.

### 1.2 `activity`는 마지막 사건의 종류다

- 도구를 관측하면 `note_tool`이 무조건 `Tool_observed`를 놓는다(`lib/keeper/keeper_turn_preview.ml:317`). 실행 전인지 끝났는지 적히지 않는다. `last_tool`의 주석도 그렇게 약속한다(`lib/keeper/keeper_turn_preview.mli`): 「This does not claim a tool is executing」.
- `activity_of_event`(같은 파일, 327)는 `TextDelta`·`ThinkingDelta`·`ReasoningDetailsDelta`·`MessageStart`를 모두 `Receiving_response`로 놓는다. 추론과 답변을 가르지 않는다.
- `MessageStop`은 `None`을 돌려준다. 응답이 끝나도 `Receiving_response`는 다음 사건까지 남는다.
- 그래서 1.1의 30초가 「응답 수신」으로 보였다.

### 1.3 열고 닫는 사건은 서버에 이미 온다

- `BeforeTurn` 훅이 공급자 요청을 미리보기에 알린다(`lib/keeper/keeper_hooks_agent_core.ml`, `BeforeTurn` → `note_request`).
- `post_tool_use`·`post_tool_use_failure` 훅이 도구가 끝난 것을 알린다(같은 파일). run tools 경로는 `pre_tool_use`도 알린다(`lib/keeper/keeper_run_tools_hooks.ml`). agent core 경로는 `pre_tool_use`를 미리보기에 알리지 않는다.
- 스트림에는 `MessageStart`·`ContentBlockStart { tool_name }`·`MessageStop`이 온다.
- 시작과 끝을 서버가 받고 있다. 미리보기가 그것을 「마지막 사건 하나」로 접는다.

### 1.4 TUI는 입력 세 갈래를 보는데 하나만 산다

- `live_chat_phase`(`lib/masc_tui/store/chat_transcript.ml:970`)는 차례로 (가) 이 TUI가 보낸 요청의 스트림 버퍼, (나) `active_turn`의 `tool_in_flight`·`phase`, (다) `active_turn.preview`를 본다.
- (가)는 내가 말을 건 턴에만 있다. 스트림은 메시지를 보낼 때 열린다(`lib/masc_tui/store/update_actions.ml`, `keeper_is_busy`).
- (나)은 서버가 보낸 적이 없다. TUI의 `active_turn`은 turns 답 위에 미리보기를 덧씌워 만든다(`lib/masc_tui/store/fleet_store.ml`, `overlay_turns_on_keepers`). turns 답은 `lane`·`turn_ref`·`started_at_unix`·`interrupt_token`·`preview_observed_through`·`preview`만 싣는다(`lib/server/server_routes_http_keeper_control.ml`). `tool_in_flight`라는 글자는 서버 코드에 들어간 적이 없다. `git log -S '"tool_in_flight"'`의 결과가 #54401의 TUI 코드뿐이다.
- 그래서 자율 턴은 (다) 하나만 쓴다. 「도구 사용 중」과 「추론 중」으로 가는 길은 실행될 수 없다.

### 1.5 자율 턴에는 스트림 길이 없다

- 채팅 스트림(`/api/v1/keepers/chat/stream`)은 요청 하나에 붙는다. 같은 `request_id`를 다시 보내면 그 요청의 기록을 이어 보낸다(`lib/server/server_routes_http_keeper_stream.ml`, `since_seq` 주석).
- 도구 승인 대기도 운영자가 시작한 턴에만 있다(같은 파일, `approval_gate` 주석: 「An autonomous cycle gets none -- nobody is watching it」).
- 자율 턴의 유일한 길은 미리보기다. 미리보기가 틀리면 화면이 틀린다.

## 2. 결정

### D1. 미리보기가 「지금 열려 있는 일」 목록을 싣는다

일 하나에 적는 것:

| 일 | 적는 것 |
|---|---|
| 모델 응답 | 지금 나오는 것(아직 없음 · 추론 · 답변), 열린 때, 지금 상태가 시작된 때 |
| 도구 | `tool_use_id`, 도구 이름, 단계(요청 · 실행), 열린 때, 지금 단계가 시작된 때 |

- 「승인 대기」와 「결과 대기」 단계는 넣지 않는다. 미리보기에 그 두 상태를 알리는 신호가 없다. 서버가 말하지 않는 값은 지어내지 않는다(RFC-0503 §0).
- 병렬 도구는 목록에 따로 남는다. 마지막 이름 하나로 덮지 않는다.
- 「마지막으로 관측한 때」는 기존 `updated_at`이 그대로 맡는다. 본문 조각이 올 때마다 열린 때를 바꾸지 않는다.
- 기존 `revision`과 Owner 묶음(인터럽트 토큰)은 그대로 쓴다. TUI는 이미 `revision`이 낮은 갱신을 버린다(`with_newer_preview`).

### D2. 열리고 닫히는 때는 실행 수명에서 온다

| 일 | 열림 | 상태 바뀜 | 닫힘 |
|---|---|---|---|
| 모델 응답 | 공급자 요청(`BeforeTurn`) | 조각의 종류(`ThinkingDelta`·`ReasoningDetailsDelta` → 추론, `TextDelta` → 답변) | `MessageStop` · `after_turn`의 글 · 새 시도 · 실패 |
| 도구 | 스트림의 도구 블록(`ContentBlockStart { tool_id }`), 또는 `pre_tool_use` | `pre_tool_use`에 요청 → 실행 | `post_tool_use` · `post_tool_use_failure` · 다음 공급자 요청 · 새 시도 · 실패 |

- 스트림의 도구 블록과 도구 훅은 같은 `tool_use_id`를 가진다(`ContentBlockStart.tool_id`, `Tool_contract.Invocation.tool_use_id`). 그것으로 도구 하나를 짝 짓는다. 스트림에 아이디가 없으면 도구 이름으로 짝 짓고, 실행 훅이 오면 아이디를 채운다.
- 도구 블록이 끝나면(`ContentBlockStop`) 그 도구가 `last_tool`이다.
- `MessageStop`은 응답만 닫는다. 응답 안에서 모델이 부른 도구는 실행 훅이 다음 단계로 옮기고, 다음 공급자 요청이 끝낸다. 공급자 요청이 새로 나가면 앞선 호출은 모두 끝난 것이다.
- `after_turn`은 모델의 응답 직후, 도구 실행 앞에서 돈다. 이 훅이 기록하는 글이 응답을 닫는다. 글이 없어도 닫는다.
- `post_tool_use`가 한 번도 오지 않는 호출은 다음 공급자 요청, 새 시도, 실패 가운데 하나에서 닫힌다.
- agent core 경로가 `pre_tool_use`를 미리보기에 알린다. 그 주위에 합성된 승인·이미지 훅이 먼저 돌고 거절된 호출은 거기까지 오지 않으므로, 그 훅이 실행의 시작이다.
- 새 시도(`note_attempt`)는 열린 일을 비운다. 이전 시도의 늦은 사건이 새 시도를 덮지 않게 한다.

### D3. `activity`는 D1의 목록에서 계산한다

| 목록 | `activity` |
|---|---|
| 준비 중인 범위가 있다 | `preparing` |
| 도구가 하나라도 열려 있다 | `tool` |
| 응답이 열려 있다 | `receiving_response` |
| 턴은 살아 있고 열린 일이 없다 | `awaiting_response` |
| 마지막 시도가 실패했다 | `failed` |

- 다섯 값은 그대로 보낸다. 뜻만 「지금」으로 맞춘다. RFC-0503이 Keepers 목록에서 「지금」과 「직전」을 가른 것과 같은 기준이다.
- `last_tool`은 그대로다. 「이 턴이 마지막으로 쓴 도구」다.

### D4. 같은 목록을 두 길에 싣는다

- 미리보기 JSON에 `open_activities`를 더한다. 두 길이 같은 JSON을 쓴다. 미리보기 방송과 turns 답의 `preview`다.
- 방송은 첫 쓰기를 바로 보내고, 그 뒤는 `post_interval_s`마다 묶어 보낸다(`lib/server/server_turn_preview_broadcast.mli`). 그대로 둔다.

받는 꼴:

```json
"open_activities": [
  { "kind": "response", "channel": "thinking", "started_at_unix": 0.0, "since_unix": 0.0 },
  { "kind": "tool", "tool_use_id": "toolu_1", "name": "Execute", "stage": "executing",
    "started_at_unix": 0.0, "since_unix": 0.0 }
]
```

- `channel`은 `none` · `thinking` · `text`다. `stage`는 `requested` · `executing`다. 스트림에 아이디가 없었던 도구는 `tool_use_id`가 없다.
- 이 필드는 더하는 것이라 옛 TUI와 옛 대시보드는 그냥 받는다. 옛 서버는 이 필드를 보내지 않는다. 그때 TUI는 지금 문구를 그대로 쓴다(D5).

### D5. TUI 상태 줄

| 열려 있는 일 | 상태 줄 |
|---|---|
| 도구 · 실행 | `도구 실행 중 · <이름> · 4s` |
| 도구 · 요청 | `도구 실행 전 · <이름>` |
| 모델 응답 · 추론 | `추론 중 · 12s` |
| 모델 응답 · 답변 | `답변 중` |
| 모델 응답 · 아직 없음 | `모델 응답 대기` |
| 없음, 턴은 살아 있음 | `열린 일 없음` |

- 도구가 응답보다 앞선다. 도구가 여럿 열려 있으면 첫째만 이름을 쓰고 `외 N건`을 붙인다.
- 시간은 `since_unix`부터 센다. 적는 법은 #54735의 `Working` 시계와 같다(`12s`, `1m 05s`). 화면은 모델이 바뀔 때 다시 그리므로 초를 위해 따로 재지 않는다.
- 내 메시지가 큐에 있으면 그 이유를 같은 줄의 맨 앞에 적는다. `메시지 1건 대기 · 지금 턴이 끝나면 실행`. 줄은 창 가장자리에서 잘리는데, 이것이 운영자가 기다리고 있는 답이다.
- 채팅 상태 줄, 턴 머리글, 로스터의 Working 상세, 키퍼 한 줄 요약이 한 함수(`Fleet_store.open_work_of_preview`)를 읽는다.
- 서버가 `open_activities`를 보내는 동안 `◐ 최근 확인 · 응답 수신` 문구는 쓰지 않는다. 보내지 않는 서버에는 지금 문구를 남긴다.
- 서버가 보낸 적 없는 (나)의 분기(`tool_in_flight`, `phase = "thinking"`)는 지운다.
- 내가 말을 건 턴(스트림 버퍼)도 같은 문구를 쓴다. 스트림 버퍼에 시작 시각이 없어서 그쪽에는 시간을 붙이지 않는다.
- 대시보드는 `activity`만 읽는다. `tool`을 이미 「도구 실행 중」으로 쓰고 있어서 #54744부터 그 말이 사실이 된다. 추론과 답변의 구분은 대시보드가 `open_activities`를 읽을 때 따라온다.

### D6. 끊긴 것은 끊긴 대로 적는다

- 연결이 끊겼거나 읽기에 실패했으면 `대기 중`으로 적지 않는다.
- #54735가 서버에서 살아 있다고 확인되지 않은 턴을 `마지막 확인 · …`로 보인다. TUI는 그 상태에서 경과 시간을 붙이지 않는다. 확인한 것은 마지막으로 본 것뿐이다.

## 3. 고르지 않은 길

### 3.1 `activity` 옆에 `current_activity`를 하나 더 둔다

- 장점: 기존 뜻을 건드리지 않는다.
- 단점: 두 값이 따로 갱신돼 어긋난다. 어긋난 쪽을 화면이 믿는다. 같은 실수를 두 값에서 한다.

### 3.2 시작한 때만 더한다

- 장점: 고칠 곳이 가장 적다.
- 단점: 끝 전이가 없으면 시작한 때는 「언제부터 멈춰 보이는지」만 늘린다. 1.1의 30초는 그대로다.

### 3.3 자율 턴에 채팅 스트림을 붙인다

- 장점: 내가 건 턴과 같은 화면을 낸다. 미리보기의 뜻을 따로 정하지 않아도 된다.
- 단점: 관객이 없는 턴마다 사건을 만들고 보내는 비용이 새로 생긴다. 요청 단위인 스트림 경로에 관전용 읽기 길을 하나 더해야 한다.
- D1~D6 뒤에 남는 어긋남이 있으면 그때 다시 본다. RFC-0486이 미러링·관전에서 정한 「서버가 프레임을 보낸다」와 같은 자리다.

### 3.4 로그와 화면을 맞추는 것으로 검증한다

- 장점: 바로 비교할 수 있다.
- 단점: 틀린 값을 로그와 화면에 같이 찍으면 일치한다. 증명이 되지 않는다.

## 4. 층

- 서버: `lib/keeper/keeper_turn_preview.{ml,mli}`(목록과 전이), 훅 호출처(1.3), `to_json`, 방송. 시험은 `test/test_keeper_turn_preview.ml`·`test/test_turn_preview_announce.ml`.
- TUI: `lib/masc_tui/protocol/wire_fleet.ml`(받는 꼴), `lib/masc_tui/store/chat_transcript.ml`(상태 고르기), `lib/masc_tui/screens_ops/keeper_dive.ml`(상태 줄).
- 대시보드: `dashboard/src/workspaces/keepers/types.ts`·`keepers-api.ts`(받는 꼴)과 문구.

## 5. 운영자에게 보이는 변화

- 채팅 창 맨 아래 한 줄: `◐ 최근 확인 · 응답 수신 · 최근 도구: Execute · 자율` → `도구 실행 중 · Execute · 4s · 자율 실행 · 4m 05s`.
- 내 메시지가 턴 뒤에서 기다리면 같은 줄 맨 앞에 그 이유가 나온다.
- 연결이 끊기면 그 사실이 나온다.
- 1.1의 30초는 도구 실행과 모델 응답을 번갈아 보여 준다.

## 6. 운영자가 정한 것

2026-11-25에 운영자가 추천안대로 하라고 했다. 세 가지는 이렇게 정했다.

1. `activity`의 `tool`은 「도구가 열려 있다」다(D3). 대시보드 문구도 같이 맞춘다.
2. 상태 줄에 경과 시간을 보인다(D5). 가만히 있는 것과 멈춘 것을 가르는 단서는 이것뿐이다.
3. D5의 큐 대기 문구를 이 범위에 넣는다.

## 7. 하지 않는 것

- 401 자동 복구. 설정돼 있지 않다.
- 자율 턴 실시간 스트림(3.3).
- 서버가 말하지 않는 값을 지어내기(RFC-0503 §0).

## 8. 검증

- 서버 시험. 사건을 순서대로 넣고 목록을 본다.
  - 도구가 끝난 뒤 모델 응답을 기다린다.
  - 응답이 끝난다.
  - 도구 승인을 기다린다.
  - 도구 둘이 병렬로 열려 있다.
  - 런타임 후보가 바뀐다.
  - 취소한다.
  - 턴이 끝난 뒤 열린 일이 없다.
- 완료 기준 두 가지.
  - 끝난 일이 열려 있게 남지 않는다.
  - 이전 실행의 늦은 사건이 새 실행을 덮지 않는다.
- TUI 시험. 목록의 경우마다 상태 줄 글자를 본다.
- 실측. 설치된 서버·TUI로 자율 턴을 받아 적고 서버 로그의 `tool_call` 시각과 대조한다. 1.1을 기준 삼아 틀린 구간의 길이를 앞뒤로 비교한다.

## 9. 구현 기록

- 서버: #54744. 미리보기의 열린 일, `activity` 계산 한 곳, agent core 훅의 `pre_tool_use`, 훅 소개의 아홉 번째 칸.
- 서버 시험: #54757(단언 둘), #54759(#54744가 빠뜨린 `last_tool` 한 줄과 단언 둘). #54744·#54757은 호스트 `Test` 결과 전에 병합됐다. 그 결과로 main의 `test_keeper_turn_preview`가 한 동안 빨간 상태였다.
- TUI: #54762.
- 대시보드: 바꿀 것이 없다(D5).
- `test_keeper_task_skill_turn_exact`의 실패 하나는 이 작업과 무관하다. 같은 base의 문서 전용 가지에서도 같은 단언이 실패한다(호스트 실행 45603088092).
- 남은 것: (나)의 죽은 분기 지우기, §8의 실측.
