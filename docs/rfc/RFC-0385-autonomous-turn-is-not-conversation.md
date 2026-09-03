---
title: 자율턴은 대화가 아니다
rfc: "0385"
status: Active
created: 2026-08-19
updated: 2026-08-20
author: vincent
related: ["0376", "0315"]
---

# RFC-0385 — 자율턴은 대화가 아니다

## 1. 결정

자율턴의 wake cue 와 최종 텍스트는 replay 대화에 남지 않는다. 다음 턴의 AGENT_CORE
체크포인트 메시지 목록에 포함되지 않는다는 뜻이다.

턴이 replay 에 남기는 것은 도구 호출과 그 결과다. 다음 사이클로 이어져야 하는
의도는 텍스트가 아니라 task / memory 도구로 표현한다. §4 가 그 자격을 실측으로
정한다.

RFC-0376 은 "발화는 도구 호출로 표현한다" 를 정했다. 이 RFC 는 같은 문장을 기억에
적용한다 — 이어져야 할 것도 도구로 표현한다.

Direct 턴(dashboard chat)의 응답 계약은 바꾸지 않는다. RFC-0376 §4.3 과 같다.

## 2. 증거

### 2.0 측정 조건

keeper `sangsu`, trace `trace-1785189111927-00005`, 2026-08-19 10:51Z 의 AGENT_CORE
체크포인트 스냅샷 1개를 셌다. 스냅샷은 턴마다 새로 쓰이므로 재측정하면 값이
이동한다. 측정 시점의 keeper 는 `paused: true` 였고, 아래 수치는 정지 직전
상태다.

### 2.1 체크포인트의 4분의 3이 자기 사고 기록이다

| 항목 | 값 |
|---|---|
| 체크포인트 메시지 | 16,247 |
| assistant | 8,073 |
| user | 6,478 |
| tool | 1,696 |

assistant 8,073 건 중 `무응답` 을 포함한 것이 6,012 건(74.5%), `새 근거 없` 을
포함한 것이 6,054 건이다. 최근 600 메시지 창으로 좁혀도 assistant 300 건 중
227 건(75.7%) 으로 비율이 같다. 오래된 잔재가 아니라 현재 진행형이다.

이 목록이 매 턴 프롬프트로 들어간다. 같은 턴의 wire capture 가 기록한
`history_message_count` 는 16,246 이고, 차이 1 은 그 턴에 append 된 user
메시지다.

모델은 자기 사고 기록 6,012 건을 예시로 보면서 다음 문장을 만든다.

### 2.2 wake cue 는 같은 문장이다

체크포인트 말미의 실제 시퀀스다.

```
user:      이전 상황을 보고 맥락에 맞게 이야기를 풀어본다. 관계 된 기억도 찾아본다.
assistant: scheduled autonomous keepalive (10:22Z). System context + memory OS recall...
user:      이전 상황을 보고 맥락에 맞게 이야기를 풀어본다. 관계 된 기억도 찾아본다.
assistant: scheduled autonomous keepalive (10:33Z). System context + memory OS recall...
user:      이전 상황을 보고 맥락에 맞게 이야기를 풀어본다. 관계 된 기억도 찾아본다.
assistant: scheduled autonomous keepalive (10:38Z). System context + memory OS recall...
```

user 측은 완전히 같은 문자열이다. 대화에서 한 사람이 같은 문장을 수천 번
반복하지 않는다. wake cue 는 대화 발화가 아니라 스케줄러 신호이며, 그것을
대화 메시지로 적재한 결과가 위 시퀀스다.

### 2.3 사고와 대화의 구분은 이미 있다

`Keeper_types_support.is_internal_history_source` 는 `world_state_prompt` 와
`internal_assistant` 를 internal 로 분류하고, `classify_history_entry` 는 전자를
`Drop_line`, 후자를 `Move_internal` 로 보낸다. 같은 trace 의 세션 디렉터리 실측:

| 파일 | 줄 | `무응답` 포함 |
|---|---|---|
| `history.jsonl` | 1,275 | 98 |
| `history.internal.jsonl` | 7,237 | 5,921 |

라벨은 이미 있고 파일도 이미 나뉜다. replay 체크포인트만 그 구분을 쓰지 않는다.
`Keeper_agent_run_finalize_response` 는 `history_assistant_source` 를 이미 인자로
받으면서 체크포인트 결정에는 넘기지 않는다.

### 2.4 비용

| 항목 | 값 |
|---|---|
| 누적 입력 토큰 | 2,003,328,910 |
| 누적 출력 토큰 | 5,997,962 |
| 누적 비용 | USD 221.89 |
| 마지막 턴 입력 | 135,321 |
| 마지막 턴 출력 | 159 |

입력 대 출력이 851 대 1 이다. 마지막 턴은 13.5 만 토큰을 넣고 "무응답" 159 토큰을
받았다.

### 2.5 turn 분류

`sangsu` 의 turn 카운터다.

| 항목 | 값 |
|---|---|
| total_turns | 29,974 |
| autonomous_turn_count | 21,704 |
| autonomous_text_turn_count | 14,216 |
| autonomous_tool_turn_count | 7,487 |
| noop_turn_count | 0 |

도구 없이 텍스트만 낸 자율턴이 14,216 건인데 noop 은 0 건이다.
`Keeper_unified_metrics_support.is_noop_cycle` 이
`(not has_text) && tools_used = []` 이고 `has_text` 가
`String.trim response_text <> ""` 이므로, 모델이 공백이 아닌 무엇이든 쓰면 noop 이
아니다. 그리고 모델은 빈 문자열을 내지 않는다. §6 이 이 판정을 다룬다.

### 2.6 지침만 고치면 단어만 바뀐다

2026-08-20, keeper `sangsu` 에서 지침 쪽 원인을 먼저 제거하고 관측했다. 제거한
것은 둘이다 — instructions 의 "새 근거가 없으면 무응답으로 끝낸다" 문장과,
119개 keeper 중 이 keeper 에만 있던 `autonomous_wake_prompt` 오버라이드
("이전 상황을 보고 맥락에 맞게 이야기를 풀어본다"). 제거 후 재개하고 18턴
(29975~29992) 을 관측했다.

| 항목 | 제거 전 누적 | 제거 후 18턴 |
|---|---|---|
| `무응답` 문자열 | assistant 의 74.5% | 0건 |
| `autonomous_text_turn_count` | 14,216 | +10 |
| `autonomous_tool_turn_count` | 7,487 | +5 |
| 텍스트 전용 자율턴 비율 | 65.5% | 67% |

문자열은 사라졌고 비율은 그대로다. 문형도 남았다.

```
이전:  scheduled autonomous keepalive (10:33Z). ... 새 근거 없음. 무응답.
이후:  scheduled autonomous keepalive (01:13Z). ... 나한테 온 새 멘션 없다.
```

29985~29992 는 8턴 연속으로 `scheduled autonomous keepalive (HH:MMZ). 이 턴에서
board sweep(masc_board_list)을 이미 실행했다` 로 시작한다. 그중 29983 · 29984 ·
29985 는 71초 안에 나왔다. 지침을 지운 뒤 문형이 흐트러지기는커녕 더 고르게
반복됐다.

이 keeper 의 체크포인트에는 §2.1 의 6,012 건이 그대로 남아 있고 매 턴 프롬프트로
들어간다. 지침을 지워도 모델이 참조하는 예시는 그대로다. 지침은 새 유입을
막았고(문자열 0건), 저량이 만드는 관성은 그대로였다(독백 4건).

대조군은 §2.3 의 구분을 그대로 따른다. 같은 지침을 가진 keeper 는 독백이 있고
(`lane-smith` 52.7%, `analyst` 1.0%), 가진 적 없는 `rondo` 는 12,441 건 중 0
건이다. `rondo` 가 0 인 이유는 지침이 없어서이기도 하지만 참조할 예시가 애초에
쌓이지 않아서이기도 하다. 두 원인은 같은 방향으로 작동한다.

## 3. 이 축은 이미 한 번 뒤집혔다

| 시점 | 정책 | 관측된 결과 |
|---|---|---|
| ~2026-08-05 | `Inert_autonomous_turn` — 도구 호출도 외부 배달도 없는 자율턴의 provider suffix 폐기 | keeper 가 자기 계획을 다음 사이클로 잇지 못함 |
| 2026-08-05 (#27014) | 휴리스틱 제거, 모든 자율 사이클을 durable user/assistant 교환으로 | §2 의 누적 |
| 2026-08-13 (RFC-0376) | 최종 텍스트의 자동 배달 경로 삭제 | 사고가 채널로 나가는 축은 닫힘 |

#27014 의 근거는 다음과 같다.

> The autonomous lane classified a bare wake as uninformative and then discarded
> the entire provider suffix when the turn made no tool call or external
> delivery. That erased assistant plans such as "I will inspect the queue next".

즉 폐기 축의 판정자는 도구 호출 유무였고, 그 축은 계획을 지웠다. 그래서
제거됐다. 같은 판정자로 되돌리는 변경은 같은 회귀를 되돌린다.

RFC-0376 은 배달을 닫았지만 replay 를 다루지 않았다. 사고가 채널로 나가는 축은
막혔고, 사고가 자기 입력으로 되돌아오는 축은 열려 있다. 이 RFC 는 후자를 닫는다.

## 4. 텍스트로 가르지 않는 이유

체크포인트에 남길 텍스트와 남기지 않을 텍스트가 같은 자리에 있다.

- `I will inspect the queue next.` — 다음 사이클이 이어받아야 하는 의도
- `새 근거 없음. 무응답.` — 이어받을 것이 없는 사고 기록

둘을 내용으로 가르려면 문구 탐지나 유사도 비교가 필요하다.
`instructions/software-development.md` §워크어라운드 거부 기준의 시그니처 2번
(string/substring 분류기 보강)에 해당하고, RFC-0376 §5 가 이미 비목표로 두었다.

도구 호출 유무로 가르는 축은 #27014 가 실측으로 기각했다.

남는 축은 하나다. 이어져야 하는 의도라면 그것을 담는 1급 수단으로 표현한다.

수단의 자격은 "그 도구가 남긴 것이 다음 턴 입력에 실제로 나타나는가" 다. §2.0 과
같은 턴에서 확인한 것은 둘이다.

| 수단 | 다음 턴에 나타나는 경로 | 같은 턴의 실측 |
|---|---|---|
| `keeper_task_create` | world observation | `unclaimed_task_count` 55, `claimable_task_count` 52 |
| `keeper_memory_write` | `extra_system_context` 의 Memory OS Recall | 14,492 bytes, 항목 41건 |

`masc_board_post` 는 board 이벤트로 관측되지만 이 턴의 `pending_board_events` 가
0 이어서 적재 경로를 실측하지 못했다. 자격은 확인 대상으로 남는다.

`keeper_plan_execute` 는 이 목록에 넣지 않는다.
`Keeper_tool_composition_surface` 의 mli 가 "runs one model-defined inline plan
through the same executor" 로 규정하듯 그 턴의 실행 수단이며, 다음 사이클로 넘길
의도의 저장소가 아니다.

"다음에 큐를 보겠다" 는 task 이거나 memory 다. 도구로 쓰면 다음 턴이 읽고,
텍스트로 쓰면 이 RFC 이후로는 읽지 않는다.

이것은 keeper 행동 계약의 변경이며, §7 이 그 이행을 다룬다.

## 5. 설계

### 5.1 replay 에서 제외되는 것

자율턴에서 다음 둘은 체크포인트 메시지 목록에 남지 않는다.

- wake cue user 메시지 (`world_state_prompt`)
- 최종 텍스트 assistant 메시지 (`internal_assistant`)

판정자는 턴이 이미 나르는 typed 라벨이다. 텍스트를 읽지 않는다.

### 5.2 replay 에 남는 것

- ToolUse / ToolResult 쌍 전체. 그 턴이 실제로 한 일이다.
- 도구가 만든 durable 사실은 각자의 저장소에 남는다. task, goal, memory,
  board post 는 이 변경의 영향을 받지 않는다.

도구를 호출한 자율턴은 그 호출과 결과가 남고 최종 텍스트만 빠진다. 도구를
호출하지 않은 자율턴은 체크포인트에 아무것도 남기지 않는다.

### 5.3 사고 기록이 남는 자리

최종 텍스트는 사라지지 않는다. 지금과 같이 turn record, raw trace,
`history.internal.jsonl` 에 남고, 대시보드 keeper chat 의 자율턴 카드
(#29108) 가 그것을 읽는다. 관측은 그대로이고 replay 만 달라진다.

### 5.4 Direct 턴

`direct_user` / `direct_assistant` 라벨을 쓰는 경로는 바뀌지 않는다.
dashboard chat 에서 응답 텍스트는 전달 수단 자체이므로 durable conversation 이다.

## 6. noop 판정

§2.5 의 `is_noop_cycle` 은 빈 문자열을 침묵의 정의로 쓴다. 모델이 만족시킬 수
없는 조건이므로 `noop_turn_count` 는 구조적으로 0 에 고정된다. 같은 형태가
`Keeper_replay_checkpoint.replay_response_text_for_persistence` 에도 있다.

이 RFC 는 두 판정 중 replay 쪽만 바꾼다. §5.1 의 라벨 판정이 앞서므로 빈 문자열
비교는 그 뒤의 잔여 경로가 된다.

`Keeper_turn_outcome.of_result_surface` 의 빈 문자열 비교는 건드리지 않는다.
RFC-0376 §4.3 이 dashboard chat 응답 계약으로 보존하기로 한 지점이다.

메트릭 쪽 `is_noop_cycle` 은 별도 문서에서 다룬다. 텔레메트리 라벨을 고치는 것은
이 RFC 가 닫으려는 replay 결함과 다른 문제이며, 함께 바꾸면 두 변경의 검증이
섞인다.

## 7. 행동 계약 이행

§4 의 결정은 keeper 가 의도를 텍스트 대신 도구로 표현할 때만 #27014 의 근거를
보존한다. 지침은 그래서 필요하다.

- 자율 지침에 "다음 사이클로 이어져야 하는 것은 task / memory 로 남긴다" 를
  명시한다. 지침 문구는 구현 PR 에서 확정한다.
- 이행 전후로 §2.5 의 `autonomous_tool_turn_count` 비율을 측정한다.

이 절의 초판은 여기에 "이행이 관측되지 않으면 §5.1 을 적용하지 않는다. 순서는
지침이 먼저다" 를 두었다. §2.6 의 실측이 그 순서를 반증한다. 지침은 새 유입을
막지만 이미 쌓인 것이 만드는 관성을 끊지 못한다. §5.1 은 지침 이행의 후행
조건이 아니라 그것과 함께 필요한 조건이다.

## 8. 비목표

- 반복 억제 장치. 문구 탐지, 유사도 비교, 발화 rate cap, noop 백오프.
  RFC-0376 §5 를 승계한다.
- 침묵 강제. keeper 가 말할지 말지는 keeper 가 정한다.
- 스케줄러 깨우기 빈도 변경.
- 외부 채널 인바운드 턴. §9 로 넘긴다.

## 9. 후속

외부 채널(discord 등) 인바운드로 유발된 턴은 dashboard chat 과 같은
`direct_assistant` 라벨을 쓴다. §2.3 의 `history.jsonl` 98 건이 그 경로이며, 그중
일부는 keeper 가 "나에게 온 것이 아니다" 로 판정한 사고 기록이다. 두 표면이 한
라벨을 공유하므로 이 RFC 의 판정자로는 갈리지 않는다. 라벨을 나누는 변경은 별도
문서에서 다룬다.

같은 조사에서 확인된 인접 사실 두 가지를 기록해 둔다. 이 RFC 의 범위는 아니다.

- discord 채널의 비멘션 메시지가 keeper 턴을 유발한다. 측정된 턴의
  `pending_mentions` 는 0 이었고 wire capture 의 user message 는 다른 봇을
  멘션한 문장이었다. 라우팅 결정은 masc 밖에 있다.
- `is_noop_cycle` 이 false 를 반환한 자율 사이클의 outcome 분류가
  `Keeper_unified_metrics_result` 에서 catch-all `else "tool_called"` 로 떨어진다.
  텍스트만 낸 턴이 텔레메트리에서 도구 호출로 집계된다.

## 10. 검증 계약

기능 단위로 검증한다.

- 도구를 호출하지 않은 자율턴 다음의 턴 프롬프트에 그 턴의 wake cue 와 최종
  텍스트가 없다.
- 도구를 호출한 자율턴 다음의 턴 프롬프트에 그 턴의 ToolUse / ToolResult 가 있다.
- 자율턴이 task / memory 도구로 남긴 사실은 다음 사이클에서 읽힌다.
- dashboard chat 에서 사용자가 물으면 응답이 그대로 표시되고 다음 턴 프롬프트에
  남는다.
- 대시보드 keeper chat 의 자율턴 카드가 최종 텍스트를 그대로 보여준다.
- 체크포인트 저장과 재적재를 거쳐 위 항목이 유지된다.
- 이행 측정: §7 의 `autonomous_tool_turn_count` 비율을 적용 전후로 비교한다.
