---
rfc: "claude-code-context-overflow-bounded-restart"
title: "Admit Claude Code bootstrap input without replaying rejected episodes"
status: Draft
created: 2026-08-12
updated: 2026-08-12
author: codex
supersedes: []
superseded_by: null
related: ["0351", "0353", "0368", "0371"]
---

# RFC: Claude Code bootstrap admission and rejected-episode fence

## 1. Decision

Claude Code `Start`를 일반적인 multi-turn replay로 취급하지 않는다. MASC는 durable
checkpoint history 전체를 `masc.claude-code.initial-turn.v1` JSON 하나로 직렬화해
Claude의 **현재 User prompt 한 개**로 전달한다. 따라서 Claude가 말하는
`single-exchange conversation`은 provider 내부 compaction으로 줄일 수 없다.

이 RFC는 그 요청을 하나의 **bootstrap episode**로 모델링한다.

1. provider-bound 입력과 hook 결과를 한 번만 준비해 frozen episode를 만든다.
2. 아직 거부된 적 없는 episode는 full-history view를 정확히 한 번 보낸다.
3. effect와 response가 시작되기 전 typed context overflow만 더 작은 history view를
   허가한다.
4. 제한된 중간 view 뒤 마지막 시도는 반드시 **bootstrap floor**를 보낸다.
5. floor도 거부되면 같은 episode의 재진입을 durable하게 차단한다.
6. episode identity가 바뀌면 floor rejection fence는 자동으로 무효화된다.
7. effect 또는 response가 관측된 episode는 입력 변경만으로 해제하지 않으며 기존
   recovery resolution을 요구한다.

durable checkpoint 원문은 어느 경로에서도 삭제하거나 덮어쓰지 않는다.

## 2. Incident evidence

2026-08-12 운영자가 clear하기 직전 `analyst` snapshot은 다음과 같았다.

- checkpoint message 수: `3,144`
- checkpoint message JSON: `4,326,961 B`
- checkpoint tool 수: `97`
- checkpoint tool JSON: `114,709 B`
- 가장 큰 단일 message JSON: `124,891 B`
- Claude Code official-client session: fresh `Start`, `turn_count = 1`

실행 영수증에서 같은 prompt-too-long 계열 실패는 `599`건이었다.

- 기간: `2026-08-10T17:51:06Z` ~ `2026-08-12T01:15:56Z`
- `claude_code.claude-opus-5-max`: `466`건
- `claude_code.claude-haiku-4-5`: `133`건
- provider 보고 request: 약 `1,697,942` ~ `2,227,128` tokens
- provider 보고 conversation: 약 `1,089,881` ~ `1,094,432` tokens

따라서 `3,144`는 재시도 횟수가 아니라 **매번 다시 보낸 durable message 수**다.
실제 장애는 동일한 약 4.33 MB history seed를 최소 599회 재전송한 replay loop다.

provider 문구의 `request - conversation` 차이는 곧바로 MASC가 줄일 수 없는 고정
overhead로 해석하지 않는다. 그 문구는 system prompt, tool definitions, attachment
content를 한 범주로 묶으며, attachment content 일부는 MASC history view 안에 있을 수
있다. shrinkable과 unshrinkable의 권위는 MASC가 frozen request composition에서 직접
분류하고, 최종 적합성은 provider floor probe가 판정한다.

## 3. Root cause

### 3.1 History is collapsed into one current prompt

`Keeper_claude_code_runtime.initial_turn_prompt`는 모든 non-System history와 현재 goal을
다음 JSON 한 개로 만든다.

```text
{
  "schema": "masc.claude-code.initial-turn.v1",
  "history": [...all selected durable messages...],
  "current_goal": "..."
}
```

Claude CLI에는 이것이 stream-json User message 하나로 전달된다. provider에는 과거
turn 경계가 없으므로 자체 compaction이 작동할 수 없다. bootstrap 크기의 소유자는
MASC다.

### 3.2 Failure recovery re-enters the identical episode

terminal provider rejection은 official-client session을 `Recovery_required`로 만든다.
현재 `plan_claim`은 다음 cycle에서 그 recovery를 fresh `Start`로 자동 supersede한다.
같은 durable history와 goal이 다시 조립되므로 provider가 거부한 episode가 변화 없이
재생된다.

### 3.3 The current prototype is bounded only inside one call

PR #28284의 첫 prototype은 exact Claude 400을 typed `ContextOverflow`로 보존하고
한 `run` 안에서 history capacity를 줄인다(처음에는 고정 세 번, 2026-09-05부터는 더 작은
view가 없을 때까지). 이는 필요한 adapter 수리지만
다음 조건을 아직 보장하지 않는다.

- 최대 횟수 전에 진짜 최소 view를 시도했는가
- 모든 history를 제거한 request도 거부되는가
- 다음 heartbeat가 같은 full episode를 다시 시작하지 않는가
- retry마다 hook, source projection, tool preparation을 다시 실행하지 않는가
- effect-fenced failure가 다음 cycle에서 fresh session으로 재생되지 않는가

따라서 typed classification과 bounded halving만으로는 root fix가 아니다.

## 4. Bootstrap episode

### 4.1 Frozen preparation

한 logical Keeper turn에서 다음 값은 provider를 spawn하기 전에 한 번만 준비한다.

- base system prompt와 turn override
- current goal
- full durable history snapshot
- extra-system-context와 source projection 결과
- exact dynamic-tool surface
- model/reasoning parameters
- official-client context codec version

축소 attempt는 frozen value를 재사용하고 **history selection만** 바꾼다. retry가
`before_turn`, `before_turn_params`, operator-note consumption, Gate replay projection,
prompt capture, tool assignment을 다시 실행해서는 안 된다.

### 4.2 Episode identity

`episode_sha256`은 view capacity와 session UUID를 제외한 logical input identity다.

```text
sha256(
  runtime_id,
  model,
  context_codec_version,
  base system prompt,
  current goal / goal blocks,
  full durable history,
  tool_surface_sha256
)
```

volatile timestamp나 retry capacity는 identity에 넣지 않는다. 동일 work item이 매
heartbeat마다 다른 fingerprint를 얻어 fence를 우회하면 안 된다.

입력 identity가 바뀌는 예는 다음과 같다.

- 새 durable message가 commit됨
- current goal/source가 바뀜
- operator가 base prompt를 수정함
- tool surface 또는 runtime/model이 바뀜

### 4.3 View identity

각 attempt는 별도의 `view_sha256`, retained/dropped atom 수, measured history bytes를
기록한다. 이것은 관측용이며 episode re-entry admission에는 사용하지 않는다.

## 5. Bootstrap floor

일반 conversation tail window는 newest atom을 보존한다. Claude `Start` bootstrap에서는
current goal이 history 밖에 별도로 존재하므로 모든 prior-history atom을 제거할 수
있다. 따라서 bootstrap 전용 floor는 다음으로 정의한다.

- current goal
- effective system prompt
- exact dynamic-tool surface
- pinned extra-system-context
- history omission preamble
- **zero shrinkable prior-history atoms**

System/extra-context message가 history list에 있으면 pinned component로 floor에 남는다.
User/Assistant/Tool prior history는 structural atom 단위로 모두 제거할 수 있다.

full view가 거부됐을 때 시도 순서는 다음과 같다.

```text
full
  -> optional midpoint 1
  -> optional midpoint 2
  -> mandatory floor
```

- view는 항상 strictly smaller여야 한다.
- 중복 boundary는 건너뛴다.
- floor와 현재 view가 같으면 provider를 다시 호출하지 않는다.
- provider dispatch 수는 strictly smaller view의 수로 bounded다. halving이면 history
  바이트의 log2 이고, view마다 atom을 하나 이상 버리므로 atom 수를 넘지 않는다.
- 마지막 dispatch가 floor가 아니면 “attempts exhausted”를 선언할 수 없다.

floor 성공은 durable history가 불필요하다는 뜻이 아니다. 그 turn의 provider bootstrap
view만 최소화됐다는 뜻이며, durable checkpoint와 memory retrieval은 그대로 남는다.

## 6. Durable replay fence

### 6.1 Session-store authority

별도 process-local counter가 아니라 `Keeper_official_client_session_store`의 durable CAS
경계가 re-entry를 소유한다. provider terminal과 replay fence를 다른 파일에 쓰면 두
write 사이 crash가 동일 effect/request를 다시 열 수 있기 때문이다.

session state에 typed input rejection을 추가한다.

```text
Input_rejected {
  episode_sha256;
  reason = Bootstrap_floor_exceeded | Effect_fenced;
  recovery evidence;
}
```

### 6.2 Admission rules

- `Bootstrap_floor_exceeded` + same episode: local typed refusal, provider spawn 없음
- `Bootstrap_floor_exceeded` + changed episode: fresh `Start` 허용
- `Effect_fenced`: episode 변경과 무관하게 operator recovery resolution 전까지 차단
- success: session `Settled`, matching rejection 없음

기존 `Recovery_required`를 무조건 fresh claim으로 auto-supersede하는 경로는 typed
context-overflow episode에 사용하지 않는다.

### 6.3 Internal retry authority

safe overflow 뒤 더 작은 view가 존재할 때만 현재 process가 exact recovery id에 대해
`Restart_fresh`를 CAS로 승인한다. 다음 attempt가 그 resolution을 소비한다.

승인 조건은 모두 참이어야 한다.

- error가 typed Claude context overflow다.
- `tool_effect_attempted = false`
- `response_emitted = false`
- next view가 current view보다 strictly smaller다.
- next view가 있다. walk는 attempt 횟수가 아니라 더 작은 view가 없는 floor에서 끝나고,
  floor rejection이 마지막이다. (2026-09-05 geek-scout 실측: 4.1MB history가 1.9MB, 507KB,
  498KB에서 거절된 뒤 floor를 묻지 않은 채 `Bootstrap_floor_exceeded`로 commit됐고,
  keeper는 두 번만 더 줄이면 빠져나올 자리에서 operator recovery에 멈춰 있었다.)

final floor rejection에는 다음 retry authority를 만들지 않고 `Input_rejected`를
commit한다.

## 7. Effect boundary

Claude process spawn 자체는 outer lane에서 계속
`Observation_unavailable`로 취급한다. adapter 내부에서 정확한 terminal frame까지
관측한 경우에만 좁은 bootstrap retry authority를 얻는다.

다음 중 하나라도 참이면 automatic retry는 같은 run과 다음 cycle 모두 금지한다.

- dynamic tool handler가 실행됨
- non-empty assistant text가 외부로 방출됨
- terminal observation이 완전하지 않음

이 경우 session state는 `Input_rejected Effect_fenced` 또는 기존 ambiguous recovery로
남고 operator가 `retry_previous` 또는 `restart_fresh`를 결정한다.

## 8. Error surface and operator action

두 실패를 구분해 노출한다.

- `context_overflow_recoverable`: 더 작은 bootstrap view를 같은 run에서 시도 중
- `bootstrap_floor_exceeded`: MASC가 소유한 history 축을 모두 제거했지만 provider가
  거부함; system prompt, current goal, tool surface, pinned context를 줄이거나 runtime을
  변경해야 함

same-episode local refusal은 provider error처럼 위장하지 않는다. dashboard blocker와
turn receipt는 다음을 포함한다.

- `episode_sha256`
- runtime/model
- rejection reason
- full/floor measured bytes
- retained/dropped atom 수
- system prompt bytes
- tool count/tool surface bytes
- current goal bytes
- operator next action

provider token 수치는 진단 원문으로 보존하되 byte/token 환산 상수로 admission을
결정하지 않는다.

## 9. Tool-surface follow-up

incident checkpoint의 97개 tool schema는 약 115 KB로 4.33 MB history보다 작았으므로
이번 사건의 1차 원인은 아니다. 다만 200k-token runtime에서 floor까지 거부되면 tool
surface가 주요 unshrinkable component가 될 수 있다.

그 경우 후속 RFC는 stable bootstrap broker를 검토한다.

- 소수의 capability-discovery/tool-dispatch tool만 항상 노출
- 실제 tool schema는 필요할 때 조회
- authorization과 typed argument validation은 host registry가 계속 소유
- tool subset 변화가 매번 provider session을 무효화하지 않도록 stable digest 유지

generic untyped `tool_call(name, json)`로 policy boundary를 우회하는 설계는 허용하지
않는다.

## 10. Required tests

### 10.1 Adapter classification

(2026-08-12 개정: CLI 2.1.228 result frame의 `terminal_reason` enum이
`prompt_too_long`을 실제 방출함을 강제 overflow stdio 캡처로 확증하여 분류
권위를 typed 축으로 이관했다. prose prefix는 enum 미방출 구버전 CLI 전용
폴백으로만 남으며 범위를 확장하지 않는다.)

1. `terminal_reason:"prompt_too_long"`을 보고한 frame은 status·문구와 무관하게
   typed context overflow가 된다.
2. `terminal_reason`이 다른 값이면 문구가 overflow prefix와 일치해도 generic
   failure로 남는다 (typed 판정이 양방향 권위).
3. `terminal_reason`이 없는 frame(구버전 CLI)에서만 exact prompt-too-long 400이
   typed context overflow가 된다.
4. unrelated 400, case drift, 중간 substring은 generic failure로 남는다.
5. tool/response activity flag가 terminal error에 보존된다.

### 10.2 Frozen episode

1. full + shrink retries 전체에서 preparation hook은 한 번만 실행된다.
2. source projection과 operator-note consumption은 한 번만 실행된다.
3. tool surface와 system prompt는 모든 view에서 동일하다.
4. capacity만 달라지고 `episode_sha256`은 동일하다.

### 10.3 Floor convergence

1. full rejection 뒤 midpoint가 성공한다.
2. midpoint가 계속 실패하면 마지막 attempt는 zero-history floor다.
3. floor 성공 뒤 turn이 settle된다.
4. floor rejection 뒤 provider attempt는 더 발생하지 않는다.
5. prior history가 단일 atom이어도 zero-history floor를 시도한다.
6. oversized current goal/pinned context는 floor rejection으로 분류된다.

### 10.4 Durable re-entry

1. 같은 episode의 다음 heartbeat는 provider를 spawn하지 않는다.
2. process restart 뒤에도 같은 episode는 spawn되지 않는다.
3. 새 durable message/goal/tool surface/runtime은 floor fence를 무효화한다.
4. effect-fenced episode는 입력 변경만으로 재개되지 않는다.
5. operator resolution만 effect fence를 해제한다.

### 10.5 Incident fixture

sanitized fixture는 최소 다음 shape를 유지한다.

- 3,144 messages
- 약 4.33 MB encoded history
- 97 tools / 약 115 KB schema
- fresh Claude `Start`

fake provider는 full과 midpoint를 거부하고 floor를 수락하는 경우, floor도 거부하는
경우를 각각 검증한다. 어떤 경우에도 다음 cycle에서 동일 full prompt가 재전송되면
실패다.

## 11. Implementation phases

### Phase A — evidence-preserving adapter

- exact Claude terminal classification
- tool/response activity flags
- typed Keeper bridge

### Phase B — frozen bootstrap projection

- preparation과 dispatch 분리
- bootstrap-specific zero-history floor
- mandatory floor sequence
- per-view observation

### Phase C — durable rejected-episode admission

- session-store typed `Input_rejected`
- same-episode local refusal
- input-change invalidation
- effect-fence operator resolution

### Phase D — rollout proof

- exact-head focused tests와 full CI
- incident-size sanitized fixture
- deployed process/commit 확인
- live full -> smaller/floor -> settle 또는 durable block 관측
- 동일 episode provider dispatch가 다시 생기지 않음을 heartbeat 두 번 이상 확인

## 12. Current PR status

PR #28284는 Phase A와 Phase B 일부의 prototype이다. 다음 조건을 만족하기 전에는
root fix 또는 merge-ready로 부르지 않는다.

- preparation이 attempt마다 재실행되지 않음
- zero-history floor가 마지막 attempt로 보장됨
- floor rejection이 durable session admission에 기록됨
- same episode의 다음 heartbeat/provider spawn이 차단됨
- effect-fenced overflow가 다음 cycle에서 auto-supersede되지 않음

## 13. Rejected alternatives

- **checkpoint clear/purge**: incident recovery일 뿐 재발 방지가 아니다.
- **fixed three halvings only**: 한 call은 끝내지만 다음 heartbeat replay를 막지 못한다.
- **process-local rejected-capacity cache**: restart가 loop를 다시 연다.
- **provider 문구의 token 숫자로 byte cap 계산**: provider tokenization과 MASC byte
  measurement를 같은 축으로 가장한다.
- **newest history atom 강제 보존**: Claude bootstrap에는 current goal이 따로 있어 진짜
  floor가 아니다.
- **retry마다 hook 재실행**: logical turn 하나에서 prompt/tool/effect preparation을
  중복한다.
- **effect 뒤 fresh restart**: external effect 또는 response를 중복할 수 있다.
- **cross-provider replay**: observation-unavailable effect를 다른 provider로 재생한다.
