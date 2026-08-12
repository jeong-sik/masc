---
rfc: "claude-code-context-overflow-bounded-restart"
title: "Recover Claude Code context overflow with an effect-safe bounded restart"
status: Draft
created: 2026-08-12
updated: 2026-08-12
author: codex
supersedes: []
superseded_by: null
related: ["0351", "0353", "0368", "0371"]
implementation_prs: [28284]
---

# RFC: Claude Code context overflow bounded restart

## 1. Decision

Claude Code의 official-client adapter가 provider terminal frame에서 다음 세
조건을 모두 직접 관측한 경우에만 이를 typed
`Agent_core.Retry.ContextOverflow`로 승격한다.

1. `is_error = true`
2. `api_error_status = 400`
3. trim한 provider `result`가 정확한 호환 prefix `Prompt is too long`으로 시작

그 실패가 **dynamic tool 진입 전**이고 **assistant response stream 시작 전**이면,
같은 runtime 안에서 fresh provider session을 만들고 provider-bound history 사본만
더 작은 atom 경계로 다시 조립한다. durable checkpoint는 수정하지 않는다.

아직 이 `(keeper, runtime)`에서 provider 거부를 관측하지 않은 첫 시도는 전체
history를 그대로 보낸다. 같은 process에서 overflow 뒤 성공한 bounded capacity가
있으면 다음 턴은 그 provider-derived capacity에서 시작할 수 있다. 운영자 선언
예산으로 미리 자르는 선제 cap은 다시 도입하지 않는다.

## 2. Problem and root cause

2026-08-12 live `analyst`는 Claude Code가 요청을 context limit 초과로 거부한 뒤
동일한 약 4.86 MB checkpoint seed를 3,144회 반복했다. 운영자가 checkpoint를
백업한 뒤 비워야만 다시 진행했다. 이 작업은 state recovery였고 root fix가
아니었다.

반복은 네 경계의 결합으로 발생했다.

1. Claude CLI는 terminal frame에 `api_error_status = 400`과
   `Prompt is too long ...`을 함께 보냈다.
2. `Runtime_claude_code`는 이를 generic `Turn_failed`로 납작하게 만들었다.
3. 따라서 `Keeper_turn_driver_try_provider.context_overflow_shrink_sequence`가
   소비하는 typed `ContextOverflow`에 도달하지 못했다.
4. failed official-client claim은 `Recovery_required`가 된 뒤 다음 claim에서 fresh
   session으로 자동 supersede되었다. fresh `Start`는 같은 durable history 전체를
   다시 seed하므로 실패 조건이 그대로 재생산됐다.

문제는 checkpoint가 크다는 사실 하나가 아니다. **provider가 이미 명시한 admission
failure가 typed retry contract에 도달하지 않아, recovery가 같은 입력을 재생한 것**이
근본 결함이다.

## 3. Existing contracts

### 3.1 `#28185`: no preemptive seed cut

`#28185`는 declared byte ceiling으로 official-client seed를 미리 자르던 경로를
삭제했다. byte cap이 provider token window의 권위인 것처럼 동작했고, provider가
수락할 수도 있던 history를 먼저 버렸기 때문이다.

본 RFC는 그 결정을 유지한다.

- 아직 working capacity를 학습하지 않은 첫 attempt는 byte-identical full seed다.
- 축소 권한은 provider의 실제 거부 이후에만 열린다.
- 이후 턴의 bounded 시작점도 같은 process가 실제 성공으로 확인한 값만 쓴다.
- 축소는 provider-bound 사본에만 적용된다.
- 성공하거나 실패해도 durable checkpoint 원문은 그대로다.

### 3.2 `#28128` / RFC-0351: reactive bounded transmission view

Codex official-client 경로는 이미 typed context overflow 뒤 같은 runtime을
구조적으로 축소해 재시도한다. 본 RFC는 새 retry 정책을 만들지 않고 그 shared
`context_overflow_shrink_sequence`와 `Runtime_model_input_tail_window` 계약을 Claude
Code에 연결한다.

### 3.3 RFC-0371: effect boundary owns retry authority

provider error 종류만으로 재시도를 허가하지 않는다. 재시도 권한은 adapter가
관측한 effect/response 경계가 소유한다. outer runtime lane의 effect disposition은
계속 fail-closed이고, 이 RFC가 여는 것은 Claude adapter 내부의 좁은 same-runtime
restart 한 번뿐이다.

## 4. Design

### 4.1 Boundary classification

Claude CLI는 이 failure에 구조화된 enum을 제공하지 않는다. 따라서 provider prose
호환은 외부 adapter 한 곳에서만 수행하고 즉시 closed variant로 바꾼다.

```text
terminal JSON
  -- is_error + status 400 + exact prefix --> Context_window_exceeded
  -- every other 400 ----------------------> Turn_failed
```

substring 검색, case folding, token 수치 추출은 하지 않는다. 문구가 바뀌면 generic
failure로 닫히며 자동 retry 권한이 생기지 않는다. Claude가 structured code를
제공하면 이 prefix adapter를 삭제하고 그 code를 단일 권위로 교체한다.

typed error는 진단 원문과 함께 다음 관측을 운반한다.

- `tool_effect_attempted`: admitted dynamic tool handler가 실행됐는가
- `response_started`: assistant stream이 시작됐는가

### 4.2 State transition

```text
full Start or Resume
  -> provider Context_window_exceeded
  -> durable claim records Provider_rejected / Recovery_required
  -> only when tool_effect_attempted=false and response_started=false:
       fresh claim auto-supersedes recovery
       Start with a smaller provider-bound history view
  -> success: settle turn 1 and remember working capacity process-locally
  -> overflow again: repeat at a strictly smaller atom boundary, shared max 3
  -> no smaller boundary or attempts exhausted: return the original typed failure
```

session recovery evidence is not skipped or rewritten. Each failed provider process closes,
the claim transitions durably, and the next internal attempt follows the existing fresh-claim
path.

### 4.3 Projection order

각 attempt는 다음 순서를 지킨다.

1. durable `initial_messages`에서 provider-bound working copy를 만든다.
2. 첫 attempt면 그대로 두고, retry면 `Runtime_model_input_tail_window`로 atom-safe
   suffix를 만든다.
3. 현재 view에서 다음 **strictly smaller** structural boundary를 계산한다.
4. Gate replay 같은 source projection은 그 뒤에 적용한다.
5. Claude `Start` prompt를 조립한다. `Resume`은 provider session을 사용한다.

tool use/result 쌍, pinned system context, newest atom floor는 기존 tail-window
불변식을 그대로 사용한다. boundary가 더 작아지지 않으면 provider를 다시 호출하지
않는다.

### 4.4 Effect and response fence

다음 중 하나라도 참이면 자동 shrink retry를 금지한다.

- dynamic tool handler에 진입했다.
- assistant response stream이 시작됐다.
- terminal frame까지의 effect 관측이 불완전하다.

금지된 실패는 기존 `Provider_attempt_effect_fenced` 경로를 유지한다. 다른 runtime
후보로 회전하거나 provider effect를 보상·재생하지 않는다. tool handler가 한 번
실행된 fixture에서는 호출 횟수가 반드시 1이어야 한다.

### 4.5 Capacity memory

성공한 bounded capacity는 `(keeper_name, runtime_id)` 키로 process-local하게만
기억한다. 다음 턴은 그 크기에서 시작해 같은 overflow 탐색을 반복하지 않는다.

이 값은 correctness state가 아니다.

- restart 시 사라져도 full seed부터 다시 안전하게 탐색한다.
- durable checkpoint나 session schema에 쓰지 않는다.
- 성공하지 않은 capacity는 기록하지 않는다.
- unbounded sentinel은 기록하지 않는다.

## 5. Safety invariants

1. **Durable fidelity**: checkpoint message를 삭제·요약·재작성하지 않는다.
2. **Provider oracle**: 미학습 첫 attempt는 full seed이며 provider의 명시 거부만
   축소 권한을 만든다. 이후 bounded 시작점은 같은 process에서 성공한 값만 쓴다.
3. **Exact classification**: unrelated 400은 typed overflow가 아니다.
4. **No effect replay**: tool 진입 뒤에는 같은 turn을 자동 재시도하지 않는다.
5. **No response replay**: response stream 시작 뒤에는 자동 재시도하지 않는다.
6. **Same runtime only**: shrink는 동일 Claude runtime의 fresh session 안에서만
   일어나며 fallback/rotation 권한을 만들지 않는다.
7. **Strict convergence**: 다음 capacity가 현재보다 작지 않으면 즉시 중단한다.
8. **Bounded attempts**: shared policy의 최대 3회 shrink를 복제 없이 재사용한다.
9. **Evidence retention**: 실패 claim과 recovery 기록은 정상 session transition을
   거친다.

## 6. Observability

각 shrink retry는 keeper log에 다음을 남긴다.

- `shrink_attempt`
- `previous_capacity_bytes`
- `capacity_bytes`

기존 Claude composition log의 `mode`, `prompt_bytes`, `system_prompt_bytes`, tool 수,
tool surface bytes를 함께 보면 full attempt와 bounded restart를 구분할 수 있다.
byte 값은 provider token 수가 아니라 MASC가 소유한 transmission view의 구조적
수렴 지표다.

후속으로 runtime manifest에 Codex와 동일한 typed shrink observation을 붙일 수 있다.
그 관측이 없다는 이유로 본 안전 수리를 지연하지 않는다.

## 7. Verification and rollout

### 7.1 Required tests

1. exact prompt-too-long 400은 `Context_window_exceeded`가 된다.
2. unrelated 400과 prefix가 아닌 문장 포함은 `Turn_failed`로 남는다.
3. tool effect 뒤 overflow는 activity flag를 보존한다.
4. response 시작 뒤 overflow는 activity flag를 보존한다.
5. Keeper 첫 attempt는 full history를 보내고 두 번째는 더 작은 non-empty history로
   성공한다.
6. tool effect 뒤 overflow는 provider attempt와 tool effect 모두 한 번뿐이며
   recovery evidence가 남는다.

### 7.2 Deployment proof

merge, build, deployment, live health를 분리해서 확인한다.

1. PR exact head의 focused tests와 CI를 확인한다.
2. main merge commit으로 `main_eio.exe`를 rebuild한다.
3. 실행 중 process의 executable/commit이 그 build를 가리키는지 확인한다.
4. oversized fixture 또는 다음 실제 Claude overflow에서 full attempt 뒤 smaller
   attempt가 관측되고 turn이 settle되는지 확인한다.
5. fleet health의 다른 degraded reason은 이 feature의 성공과 분리해 보고한다.

## 8. Non-goals and rejected alternatives

- **checkpoint clear/purge**: incident recovery일 뿐 root fix가 아니다.
- **preemptive `max-prompt-bytes` cap**: `#28185`의 제거 사유를 되살린다.
- **durable history truncation/compaction**: 본 수리는 transmission view만 바꾼다.
- **string search anywhere else**: provider compatibility parser 밖의 prose 분류는
  금지한다.
- **retry after effects or streamed response**: duplicate effect/delivery 위험 때문에
  금지한다.
- **cross-provider fallback**: effect 관측이 불완전한 official-client attempt를 다른
  provider로 재생하지 않는다.
- **Claude context policy 일반화**: structured enum이 없는 이 transport의 좁은 adapter
  수리다. shared retry/tail-window 정책 자체는 변경하지 않는다.

## 9. Integration note

`#28263`은 본 구현 전에 main에 머지되어 official-client context codec을 v2로
hard-cut했다. shrink 측정기는 별도 JSON 형식을 복제하지 않고
`Host.encode_history_message`에 위임한다. 따라서 System과 history role 모두 실제
provider projection과 같은 v2 envelope를 사용한다. focused shrink fixture는 full
attempt와 bounded retry 양쪽의 schema가 현재 codec인지 확인한다. compatibility
reader나 v1/v2 이중 경로는 만들지 않는다.
