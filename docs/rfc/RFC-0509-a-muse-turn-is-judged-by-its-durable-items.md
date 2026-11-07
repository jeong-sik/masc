---
rfc: "0509"
title: "Muse 턴이 바깥에 남긴 일은 그 턴의 durable 항목으로 판정한다"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: claude-code
supersedes: []
superseded_by: null
related: ["claude-code-context-overflow-bounded-restart"]
implementation_prs: []
---

# RFC-0509 — Muse 턴이 바깥에 남긴 일은 그 턴의 durable 항목으로 판정한다

## 0. 요약

- Muse 레인은 호스트가 턴을 받는 순간 그 시도를 `Observation_unavailable` 로 적는다.
- 첫 모델 호출이 거절돼 아무 일도 없던 턴도 똑같이 적힌다.
- 그래서 8일 동안 Muse 실패 2,131번이 다음 런타임으로 넘어가지 못했다.
- 이 RFC는 판정 시점을 턴의 끝으로 옮긴다.
  - 턴이 typed terminal 로 끝나면 그 턴의 durable 기록을 빈틈없이 읽는다.
  - 항목이 사용자 입력과 추론뿐이면 `No_effect_observed` 로 둔다.
  - 읽지 못했거나 다른 항목이 있으면 지금처럼 `Observation_unavailable` 이다.

## 1. 사건

`<base>/.masc/logs/system_log_*.jsonl` 8일치(10-30~11-06)에서 셌다.
`keeper cycle FAILED` 줄 중 `runtime=muse` 이고 `observation_unavailable` 인 줄이다.

```sh
cd <base>/.masc/logs
LC_ALL=C rg -N -F 'keeper cycle FAILED' system_log_2026-1*.jsonl \
  | LC_ALL=C rg -F 'observation_unavailable' | LC_ALL=C rg -F 'runtime=muse' | wc -l
```

| 날짜 | cycle |
|---|---:|
| 10-30 | 83 |
| 10-31 | 8 |
| 11-01 | 111 |
| 11-02 | 113 |
| 11-03 | 61 |
| 11-04 | 380 |
| 11-05 | 1,182 |
| 11-06 | 193 |
| 합 | 2,131 |

거절 원인(시도 기록의 오류 글로 나눔, 이 표에만 쓴다)이다.

| 원인 | cycle |
|---|---:|
| 한도·속도 제한 | 1,462 |
| context 창 초과 | 309 |
| 로그인 안 됨 | 272 |
| 연결 실패 | 54 |
| 응답 없음·시간 초과 | 21 |
| 그 밖 | 13 |

- Keeper 17명에게서 났다. 11-05 에는 한 Keeper 가 977번 실패했다.
- 2,131번 중 2,130번에 `deferred_next_runtime=none` 이 찍혔다.
  - fence 가 붙은 시도는 다음 후보로 가지 않는다.
  - `lib/keeper_runtime/keeper_runtime_failure_route.ml` 234~243행이 `Fenced_observation_unavailable` 로 끝낸다.
- 한도·context·로그인 거절은 첫 모델 호출에서 온다. 그 앞에서 도구가 돌 자리가 없다.
- #49369: 한도가 풀리는 시각까지 쉬게 하는 수리는 fence 없는 시도에만 걸린다.
  Muse 한도 거절은 그 수리가 들어가도 실패로 남는다.
- #42666: 추론만 하고 빈 답을 낸 턴도 같은 이유로 막힌다.

## 2. 지금 규칙

`lib/keeper/keeper_muse_runtime.ml`(main 6415b78c514)이다.

- 1387~1395행 `on_turn_started` 가 `observe_transport_uncertain ()` 을 조건 없이 부른다.
- 370행 `failure_leaves_effects_unknown` 은 `Acknowledged` 면 오류와 상관없이 `true` 다.

주석이 드는 근거는 셋이다.

1. 호스트 규칙이 허락한 내장 도구는 MASC 에 묻지 않고 돈다.
2. subagent·workflow 는 MASC 가 읽지 않는 자식 세션에서 도구를 돌린다.
3. live 전달만으로는 턴을 다 봤다고 증명할 수 없다.
   `lib/runtime/runtime_muse_serve.ml` 1073~1076행이 같은 말을 한다.

셋 다 맞다. 셋 다 "턴 안에서 무엇이 시작됐는지 모른다"는 말이다.
턴의 durable 기록을 읽으면 그것을 안다.
완료된 턴은 이미 그 기록을 읽는다. 답 글을 증명하려고 읽는다.
`lib/runtime/runtime_muse_serve.ml` 1152행 `read_durable_turn` 이다.
실패한 턴은 읽지 않는다.
같은 파일 1408~1436행의 match 가 `Terminal_completed` 에서만 `read_durable_turn` 을 부른다.

## 3. MSP 가 보장하는 것

근거는 `Runtime_muse_msp` 가 따르는 스키마다.
`github.com/meta-models/muse-code-sdk` 의 `schema/msp/msp.d.ts`, 커밋 42c7658(host 1.4.14)이다.

- 호스트가 턴 안에서 하는 일은 그 턴의 항목(item)으로 남는다. `ItemKind` 는 18가지다(1285행).
  - 내장 도구 호출은 `toolCall` 이다.
  - subagent·workflow 는 부모 턴의 `subagent`·`workflow` 항목이다.
  - hook 실행은 `hookRun` 항목이다. hook 은 `userPromptSubmit`, `preLLMCall` 처럼 첫 모델 호출 앞에서도 돈다(1001행).
- `turnId` 가 비는 종류는 정해져 있다(1244행).
  - `userShell`, 세션 경계의 `hookRun`, `monitorFeed`, `sideChat`, `damagedRange`, `earlierHistory` 다.
  - MASC 가 보내는 요청은 `initialize`, `session/start`, `session/resume`, `session/setModel`, `session/setApprovalMode`, `turn/start`, `approval/decide`, `model/list`, `usage/read`, `view/page` 뿐이다. `session/userShell`, `session/sideChat` 은 보내지 않는다.
  - 세션 경계 hook 은 `turn/start` 앞에서 돈다. 그 구간의 판정은 이 RFC가 바꾸지 않는다(§5).
  - 이 종류의 event 가 읽은 범위 안에 끼어 있어도 이 턴의 항목이 아니다. 그래서 `turnId` 로 거르면 빠진다.
- `view/page` 는 durable 기록만 돌려준다. 페이지는 이어져 있어 cursor 를 건너뛰지 않는다(`ViewPageResult`, 3879행).
- 바깥에 남길 수 있는 항목은 열릴 때부터 durable 이다(item id 규칙, 1134행).
  - 열릴 때 durable 이 아닌 종류는 `agentMessage`·`reasoning` 둘뿐이다.
  - 이 둘은 `item/completed` 가 없으면 durable 범위에 없다.
- `view/gap` 은 다른 알림과의 순서를 약속하지 않는다(3839행). terminal 뒤에 올 수 있다.
  그래서 live 로 받은 항목만으로는 판정하지 않는다.

## 4. 제안 규칙

턴이 typed terminal(`Terminal_completed`, `Terminal_failed`)로 끝나면 MASC 는 그 턴의 durable 범위를 읽는다.
읽는 방법은 완료된 턴의 `read_durable_turn` 과 같다.
terminal cursor 에서 거꾸로 이 턴의 `turn/started` 까지 `view/page` 로 읽는다.

읽은 범위에서 이 턴(`turnId` 가 같은) 항목의 종류를 본다.

| 항목 종류 | 판정 |
|---|---|
| `userMessage` | MASC 가 보낸 입력이다. 바깥에 남는 것이 없다. |
| `reasoning` | 모델 안의 추론이다. 바깥에 남는 것이 없다. |
| 나머지 모든 종류(MASC 가 모르는 종류 포함) | 바깥에 무엇인가 남겼을 수 있다. |

- 이 턴의 항목이 `userMessage`·`reasoning` 뿐이고, 아래 live 조건도 맞으면 그 턴은 조용했다.
  시도의 판정은 `No_effect_observed` 로 남는다.
- live 조건: 이 턴에서 `agentMessage` 항목이 열리거나 그 글 조각이 온 적이 없다.
  - 스트리밍되다 끊긴 답 글은 `item/completed` 가 없어 durable 범위에 없다. live 로만 보인다.
  - live 관측은 조용함을 거부할 때만 쓴다. 조용함을 증명하는 데는 쓰지 않는다.
- 다른 종류가 하나라도 있으면 `Observation_unavailable` 이다.
- 읽기가 실패하면 `Observation_unavailable` 이다.
  - 오류 응답, 시간 초과, 다른 세션의 event, 시작 경계를 못 찾음이 모두 여기에 든다.
- typed terminal 이 아닌 끝도 `Observation_unavailable` 이다.
  - `Terminal_host_died`, `Terminal_cancelled`, 모르는 terminal 이다.
  - 연결 끊김, 시간 초과, 예외도 같다.
- MASC 동적 도구가 불렸으면 `Effect_attempted` 가 그대로 남는다. 조용하다는 증명은 그 판정을 바꾸지 않는다.

`agentMessage` 를 조용한 종류에 넣지 않는 이유가 있다.
스트리밍된 글은 대화 화면이나 Discord 로 이미 나갔을 수 있다.
bounded-restart RFC §7 도 "non-empty assistant text가 외부로 방출됨"이면 재시도를 막는다.
#49369 와 #42666 의 턴에는 답 글이 없다. 이 선택은 두 사건의 수리를 막지 않는다.

조용한 종류는 두 개로 시작한다. `compaction` 처럼 바깥에 남는 것이 없어 보이는 종류도 뺐다.
측정한 사건에 그런 종류가 없다. 더할 때는 사건과 근거를 같이 낸다.

## 5. 바꾸지 않는 것

- `turn/start` 를 다 보내기 전 실패의 판정은 그대로다.
- fence 가 하는 일(다음 후보로 넘기지 않음, 운영자 알림)은 그대로다. 조용한 턴이 fence 를 받지 않게 될 뿐이다.
- 다른 레인(Codex, Claude Code, Antigravity)은 건드리지 않는다.
  - Antigravity 는 이미 내장 도구가 시작될 때만 `Observation_unavailable` 로 적는다(`lib/keeper/keeper_antigravity_runtime.ml` 291~294행).
- 새 상태·필드·Gate 를 더하지 않는다. `Keeper_provider_attempt_effect` 의 세 값은 그대로다.
- 완료된 턴의 답 글 증명(`durable_final_text`)은 그대로다.

## 6. 구현

PR 하나로 한다. 두 모듈의 타입이 같이 바뀐다.

- `Runtime_muse_serve`
  - durable 범위 읽기와 그 해석을 나눈다. 답 글 해석은 완료된 턴에만 쓴다.
  - 실패한 typed terminal 에도 범위를 읽는다.
  - 이 턴이 조용했는지를 닫힌 합타입 `turn_items` 로 만든다.
    - 조용함, 바깥 항목 있음, 읽지 못함의 세 경우다.
    - terminal 직후 stream event `Turn_items_read` 로 한 번 보낸다.
- `Keeper_muse_runtime`
  - `on_turn_started` 의 표시는 남긴다.
    - 증명 없이 끝나는 길은 모두 `Observation_unavailable` 로 남는다.
    - 예외, 연결 끊김, 시간 초과, host 종료, 취소가 여기에 든다.
  - 조용하다는 증명이 오면 그 표시를 `No_effect_observed` 로 되돌린다.
    - compare-and-set 이라 `Effect_attempted` 는 되돌리지 않는다.
  - `failure_leaves_effects_unknown` 은 `Acknowledged` 에서 조용하다고 증명된 terminal 오류만 `false` 로 둔다.
- 시험(`test_keeper_muse_runtime` 의 가짜 호스트)
  - 사용자 입력과 추론 뒤 한도 거절이 오면 `No_effect_observed` 다.
  - `toolCall` 항목 뒤 실패가 오면 `Observation_unavailable` 이다. 기존 시험이 이미 본다.
  - durable 읽기가 실패하면 `Observation_unavailable` 이다.
  - durable 범위에 완료된 `agentMessage` 가 있으면 `Observation_unavailable` 이다.
  - live 로 답 글 조각이 온 뒤 그 글이 완료되지 않은 채 한도 거절이 오면 `Observation_unavailable` 이다.

## 7. 완료 판정

- 배포 뒤 8일치 system_log 에서 §1 과 같은 방법으로 센다.
  - 한도·context·로그인 원인으로 `observation_unavailable` 이 된 Muse cycle 이 0 이다.
  - 같은 원인의 실패가 `deferred_next_runtime` 에 다음 후보를 적는다. 후보가 있는 Keeper 에 한한다.
- `toolCall` 항목이 있던 실패는 계속 `observation_unavailable` 이다.

## 8. 버린 대안

- live 로 받은 항목만으로 판정한다.
  - `view/gap` 이 terminal 뒤에 올 수 있어 증명이 되지 않는다.
- 오류 글(한도, 로그인)로 판정한다.
  - 문자열 분류다.
  - 첫 모델 호출 앞의 hook 이 이미 돌았을 수 있다. 그 hook 은 `hookRun` 항목으로만 보인다.
- `Terminal_failed` 의 `quota` 필드로 판정한다.
  - 거절이 첫 호출에서 왔다는 뜻이 아니다. 도구를 돌린 뒤 둘째 호출에서 왔을 수 있다.
- 한도 거절만 따로 다룬다.
  - context 초과와 로그인 거절(581번)이 그대로 남는다. 원인은 같은 자리 하나다.
