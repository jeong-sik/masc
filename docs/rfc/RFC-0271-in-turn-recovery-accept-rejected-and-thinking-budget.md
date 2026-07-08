# RFC-0271 — accept-rejected (No_usable_progress) 키퍼 턴의 in-turn recovery arm + thinking-budget ceiling enforcement

| | |
|---|---|
| Status | Draft |
| Subsystem | `lib/keeper/keeper_turn_driver_try_runtime`, `lib/runtime/runtime_inference`, `lib/worker_oas`, `lib/runtime/runtime_toml`; **§4.5**: `lib/keeper_runtime/keeper_internal_error`, `lib/keeper_tooling/keeper_tool_response`, `lib/keeper/keeper_error_classify`, `lib/keeper/keeper_unified_turn_failure`, `lib/keeper/keeper_turn_driver_try_provider` |
| Related | RFC-0222 / RFC-0262 (accept verdict 소유), RFC-0265 (reroute seam), RFC-0207 Part B / RFC-0260 (provider-failure failover), RFC-0012 (mid-turn watchdog), RFC-0082 (recovery escalation·N-of-M 원칙), RFC-0136 (turn semantics 경계), RFC-0042 (typed closure), **RFC-0326 (§4.5 typed stop_reason — typed-vs-string 선례), RFC-0313 W3 (§4.5 auto-pause dead → soft-park 부재)** |
| Date | 2026-06-20 |
| Author | vincent (+ Claude Opus 4.8) |

## 1. 동기 (Motivation)

키퍼가 thinking 토큰만 소비하고 deliverable(text·tool_use) 없이 `end_turn`으로 종료하면, accept 레이어가 그 턴을 `No_usable_progress`로 거부한다. 거부 판정 자체는 정확하다 — 진전이 0인 턴이다. 문제는 **그 정확한 거부에 대한 교정 행동이 없다**는 것이다. 거부 직후 즉시 `Error err`로 단일 runtime turn이 종결되고, 누적되면 키퍼는 `completion_contract_auto_paused`로 PAUSE된다.

실측 (2026-06-20, `<base-path>/.masc` 라이브; shell-home shorthand가 아님):

```
scope=ollama_cloud.deepseek-v4-flash  reason_kind=no_usable_progress
shape=thinking_only stop_reason=end_turn
text_chars=0 tool_use_count=0 thinking_chars=31397
last_tool=Execute last_tool_effect=mutating  (도구 ~29회 후 발생)
```

`issue_king`·`sangsu`가 flash 런타임에서 이 패턴으로 반복 종료했다. flash는 `tools-support=true`로 선언돼 있으나 — capability 선언은 "도구를 부를 수 있다"는 가능성일 뿐 실제 호출 보장이 아니다 — 도구 다회 사용으로 커진 컨텍스트에서 thinking에 턴을 소진하고 deliverable 없이 멈췄다.

원인 분석은 두 축으로 분리한다. 첫째, **terminal shape 문제**: 어떤 이유든 runtime이 `thinking_only + end_turn + deliverable=0`으로 끝나면 현재 keeper는 교정 없이 terminal error로 빠진다. 이는 context pressure가 원인이어도, 모델의 over-thinking이 원인이어도 동일하게 발생하는 코드 경로 결함이다. 둘째, **budget producer-consumer 문제**: `max_thinking_budget`이 parse-only라 thinking length를 제한하지 못한다. 이 RFC는 "budget 하나가 모든 사례의 단일 원인"이라고 주장하지 않는다. budget wiring은 과도한 thinking을 줄이는 preventive arm이고, recovery arm은 context pressure 등 다른 원인으로도 남을 수 있는 `thinking_only` terminal shape를 bounded하게 처리하는 corrective arm이다.

두 층위의 결함이 합성된다:

1. **recovery 부재**: accept가 `thinking_only`를 거부한 직후 `keeper_turn_driver_try_runtime.ml`의 `Ok run_result`(accept-rejected) 분기가 즉시 `Error err`를 반환한다. 같은 턴을 `enable_thinking=false`로 재시도하거나 tool-reliable runtime으로 reroute하는 경로가 없다.
2. **thinking 무제어**: `runtime.toml`의 `max_thinking_budget`이 파싱만 되고 request-path 소비자가 0이라, thinking 길이를 코드가 cap하지 못한다. `thinking_chars=31397`은 모델 자율이다.

## 2. Non-goals / 경계

이 RFC는 다음을 **소유하지 않는다** (인용·재사용만):

- **accept 판정 기준 무변경.** `thinking_only / end_turn / deliverable=0 → No_usable_progress` 판정은 RFC-0222(typed acceptance) / RFC-0262(completion authority) 소유다. recovery arm은 거부 verdict를 **소비**만 하고, accept를 substring/permissive 로직으로 넓히지 않는다.
- **reroute ordering / visibility 규율 무변경.** runtime 후보 선택과 deterministic ordering·non-silent floor는 RFC-0265 소유다. 우리는 그 seam(`keeper_turn_driver.run_named`, `media_failover`)을 재사용하고, trigger(accept-rejection)만 신규로 추가한다.
- **provider-failure failover 무변경.** HTTP error·empty·health 기반 failover는 RFC-0207 Part B / RFC-0260 소유다. 우리 trigger는 **성공 응답이 accept를 통과 못 한** 경우로, provider-error trigger와 구분된다.
- **mid-turn watchdog 무변경.** 시간-기반 hung-fiber kill(`Mid_turn_no_progress`, `progress_timeout_sec`)은 RFC-0012 소유다. 우리는 그와 공존하며, recovery 재시도가 watchdog에 죽지 않도록 progress 신호를 emit한다(§4.3).
- **OAS 경계 무변경.** thinking/recovery 개념은 OAS로 넘기지 않는다.

## 3. 진단 (코드 근거)

| 사실 | 위치 | 내용 |
|---|---|---|
| 거부 판정 발원 | `lib/keeper_tooling/keeper_tool_response.ml:34-42` | `has_deliverable_content`가 false면 `{kind=No_usable_progress; reason}`. |
| deliverable 판정 | `agent_sdk/.../response_shape.ml:90,96-103` | `has_deliverable_content = text_chars>0 ‖ tool_use_count>0`. `thinking_only` = thinking_blocks>0 ∧ text=0 ∧ tool=0. |
| 거부 후 즉시 종결 | `lib/keeper/keeper_turn_driver_try_runtime.ml:196-212` | `Ok run_result`(accept-rejected) 분기는 `accept_rejected_error` 생성 후 즉시 `Error err`. `rest` 후보로 loop 안 함. recovery arm 0. |
| 거부 사유 이미 typed | `lib/keeper_runtime/keeper_internal_error.ml:135` | `Accept_rejected of { scope; model; reason_kind; reason }`는 이미 typed variant. **string 분류기 추가 불필요** (RFC-0042 준수). |
| budget parse-only | `lib/runtime/runtime_toml.ml:413,452` → `runtime_schema.ml:142` | `max_thinking_budget` 파싱되어 schema에 저장. |
| budget 소비자 0 | `lib/runtime/runtime_inference.ml:26-32` | `thinking_budget=None` 고정. 주석: "ceiling일 뿐 active budget 아님". request-path consumer 0건(rg). |
| request 미wiring | `lib/worker_oas.ml:67,180-181` | `enable_thinking`만 설정, `with_thinking_budget` 호출 0. |
| capability gate 존재 | `lib/runtime/runtime_agent_context.ml:333-334` | `with_thinking_budget`는 `Some`-gated — budget 미지원 runtime은 자동 no-op. |
| 현 reroute 범위 | `lib/keeper/keeper_turn_driver.ml:128-157` | proactive reroute는 RFC-0265 modality만. text 턴은 명시적으로 untouched. |
| mutating-empty truncation 미커버 | `lib/keeper_runtime/keeper_internal_error.ml:650-935` | 세 no-progress kind(`Empty`/`Thinking_only`/`Read_only`)가 모두 `tool_effects_seen=[]`(또는 read-only) 요구. **도구 실행 + 빈 마무리**(`any_mutating_tool=Some true`, `response_shape=Empty`, `tool_effects_seen<>[]`)는 어느 kind에도 안 걸려 catch-all `None` → recovery 0. (§9 2026-07-09 refresh.) |
| `stop_reason` typed 아님 | `lib/keeper_runtime/keeper_internal_error.mli:116-125`, `lib/keeper_tooling/keeper_tool_response.ml:35-44` | `Accept_rejected` 레코드에 `stop_reason` field 없음 — `max_tokens` truncation은 free-text `reason` 문자열에만 존재. accept는 `stop_reason`을 버려 truncation과 clean empty `EndTurn`을 동일 취급. OAS `Response_shape.ended_without_deliverable_content`는 `EndTurn`에 한정해 truncation을 제외하지만 masc는 이 함수를 안 씀. |

## 4. 설계

우리가 **새로 정의**하는 것은 둘뿐이다.

### 4.1 typed `recovery_action` variant (in-turn recovery arm)

`keeper_turn_driver_try_runtime.ml`의 accept-rejected 분기에, 즉시 `Error err` 대신 typed closed-sum을 거쳐 한 번의 결정론적 recovery를 시도한다.

```ocaml
(* 거부 verdict(Accept_rejected{reason})를 소비하고 단일 recovery 행동으로 매핑.
   closed sum 이라 새 행동 추가 시 모든 dispatch site 가 컴파일 타임에 강제됨
   (RFC-0082 §3.1 N-of-M 거부 원칙). *)
type recovery_terminal =
  | Recovery_rejected_again      (* recovery attempt 도 accept 를 통과하지 못함 *)
  | No_tool_reliable_candidate   (* reroute 후보 없음 *)
  | Recovery_budget_exhausted    (* 이 RFC 의 bounded recovery ceiling 도달 *)

type recovery_action =
  | Retry_no_thinking            (* 같은 runtime, enable_thinking=false 로 request shape 변경 *)
  | Reroute_tool_reliable        (* RFC-0265 seam 재사용, tool-reliable 후보로 1회 reroute *)
  | Terminal_no_usable_progress of recovery_terminal
      (* 더 시도 안 함, 기존 typed terminal 그대로 surface *)
```

규칙 (결정론):

1. 거부가 `thinking_only`(deliverable=0, thinking>0)이고 현재 attempt가 `enable_thinking=true`였으면 → `Retry_no_thinking`. **request shape를 결정론적으로 바꾼다** (같은 요청 반복이 아니다).
2. `Retry_no_thinking`도 거부되거나 thinking-off가 이미였으면 → tool-reliable 후보가 있으면 `Reroute_tool_reliable`(RFC-0265 seam, non-silent WARN + deterministic ordering 상속), 없으면 `Terminal_no_usable_progress`.
3. recovery는 **최대 1회 re-shape attempt + 최대 1회 reroute**로 bounded. 그 다음은 `Terminal_no_usable_progress <reason>`로 닫고, 기존 typed `No_usable_progress` error를 그대로 surface한다. `Terminal_no_usable_progress`는 fallback-by-hand가 아니라 recovery FSM의 정상 terminal state다.
4. `Accept_rejected.reason_kind -> recovery_action` 매핑은 catch-all `_` 없이 exhaustive match로 구현한다. 새 typed reason이 추가되면 컴파일러가 recovery 매핑 누락을 잡아야 한다.

### 4.2 thinking-budget ceiling enforcement

`max_thinking_budget`(이미 parse됨, 소비자 0)을 request-time에 실제 적용한다. **죽은 설정을 enforce로 전환**하는 것이지 새 cap 추가가 아니다.

- producer(`runtime_toml` 파서)와 consumer(`worker_oas` request 구성, `with_thinking_budget`)를 **같은 PR에서 동시 wiring** (RFC-0082 §3.5 partial-site 금지).
- per-runtime config-driven 값으로만 (RFC-0012의 turn_timeout per-runtime 경계와 동형). 하드코딩 글로벌 금지.
- budget 미지원 runtime은 `Some`-gated no-op 유지(`runtime_agent_context.ml:333-334`). capability 존중 (RFC-0265).
- ceiling은 adaptive budget의 상한이지 active budget 치환이 아니다(RFC-0136 semantics 경계, `runtime_inference.ml:26` 주석과 정합).
- producer semantics: `Runtime_schema.max_thinking_budget`가 `Some n`이면 `runtime_inference`가 `thinking_budget=Some n`을 산출한다. `None`이면 현재와 동일하게 request field를 생략한다.
- consumer semantics: `worker_oas`는 `thinking_budget=Some n`일 때만 `with_thinking_budget n`을 호출한다. request construction과 test fixture 모두 이 field를 직접 관찰해야 한다.
- provider non-compliance semantics: provider가 budget field를 무시하고 긴 thinking-only 응답을 반환해도 response text를 truncate하거나 synthetic deliverable을 만들지 않는다. accept layer가 그대로 `No_usable_progress`를 만들고 §4.1 recovery FSM이 처리한다. 즉 budget은 best-effort provider control이고, terminal correctness는 accept/recovery가 소유한다.

### 4.3 watchdog 공존 (RFC-0012 상호작용)

recovery 재시도는 새 attempt 시 `record_progress` hook으로 `last_progress_at`을 갱신한다. 그렇지 않으면 RFC-0012의 `elapsed_since_progress > progress_timeout_sec(300s)` watchdog이 recovery 중인 턴을 `Mid_turn_no_progress`로 죽인다. recovery는 watchdog과 **공존**하는 동시 terminator를 전제로 설계한다.

### 4.4 budget 회계

recovery 재시도가 `autonomous_max_turns_per_call` budget을 silent 소비하면 budget-exhausted 회귀가 된다. `Retry_no_thinking` 재시도는 별도 회계에 명시 포함하거나 격리한다(RFC-0082 §7 probe-turn 제약과 동형).

### 4.5 truncation-aware continuation (도구-productive 턴, `stop_reason=max_tokens`)

§4.1 rule 1의 `Retry_no_thinking` gate(`should_retry_no_thinking`)는 `Thinking_only_no_progress`에만 발동한다. 세 recovery kind가 모두 `tool_effects_seen=[]`(또는 read-only)를 요구하므로, **도구를 여러 번 실행한 턴이 마무리 응답만 빈** 경우(`any_mutating_tool=Some true`, `response_shape=Empty`, `tool_effects_seen<>[]`)는 catch-all `None`으로 빠져 recovery가 0이다. 그리고 이 empty는 대개 `stop_reason=max_tokens` truncation이다 — 사고가 공유 출력 예산을 소진한 것이며, §4.2 ceiling은 answer 몫을 예약하지 않는다(thinking과 answer가 단일 `max_tokens`를 공유; §9 2026-07-09 refresh, `runtime_inference.ml:18-30`). accept layer가 `stop_reason`을 버려 이 truncation을 clean empty `EndTurn`과 동일 취급해 `No_usable_progress` terminal로 만든다.

설계 (§4.1 corrective 라인의 연장, budget cap 아님):

1. **typed `stop_reason`을 accept-rejection에 스레드한다.** OAS `Types.stop_reason`(이미 typed: `EndTurn | MaxTokens | …`)을 `Keeper_internal_error.Accept_rejected`에 직접 실어, 하류가 substring 매칭 없이 판별한다. free-text `reason`에서 `"max_tokens"`를 찾는 문자열 분류기 추가는 **금지**한다(RFC-0042 / RFC-0326 typed-vs-string 원칙 — 문자열 분류기는 추가가 아니라 제거 대상).
2. **truncation을 completion-contract violation에서 분리한다.** OAS `Response_shape.ended_without_deliverable_content`가 `stop_reason=EndTurn`에 한정해 truncation을 제외하는 것과 정합하게, `stop_reason=MaxTokens`인 empty/thinking_only 응답은 completion-contract violation이 아니라 **truncation(budget/continuation event)**으로 분류한다. `is_completion_contract_violation`은 이 케이스에 `false`를 반환한다(recoverable no-progress → rotation cap 해제).

   **구현 정정 (2026-07-08): `counts_toward_crash`는 직접 손대지 않는다.** 초안은 "counts_toward_crash에서 truncation 제외"를 명시했으나, 코드 확인 결과 그것만으로는 위험하다 — crash 누적은 in-turn recovery가 소진된 *뒤* 실패 경로에서만 계산된다. 실제 기전은 continuation(§4.5.3)이다: continuation이 성공하면 턴이 성공해 실패 경로 자체를 우회하므로 crash가 누적되지 않는다(이것이 §9 mad-improver의 10회 연속 실패를 끊는다). continuation이 실패한 truncation(계속 truncate)은 crash 안전망(→ `Keeper_fiber_crash` → supervisor → Dead → operator)을 **의도적으로 보존**한다. crash를 무조건 제외하면 매 턴 continuation이 실패하는 keeper가 보이지 않는 무한 no-progress 루프에 빠져(보이는 crash를 안 보이는 hang으로 치환 = CLAUDE.md "symptom 억제" 워크어라운드), 더 나쁘다. `thinking_was_enabled=false`(이미 thinking off인데 truncate)인 케이스도 continuation gate에서 걸러져 crash 경로로 정상 노출된다.
3. **continuation arm**: `stop_reason=MaxTokens` truncation이고 직전 attempt가 `enable_thinking=true`였으면 → 기존 `Retry_no_thinking` action을 재사용해 **같은 checkpoint(도구 결과 포함)에서 thinking off로 마무리 응답만 재생성**한다. thinking off는 공유 `max_tokens` 예산 전부를 answer에 할당하므로 truncation을 해소한다. 이 arm은 `tool_effects_seen` 조건에 **무관**하게 발동한다(§4.1의 `[]` 제약을 truncation 케이스에서 해제). bounded once/turn(기존 `recovered` guard 재사용).
4. **도구 재실행 없음**: continuation은 같은 message history 위의 새 provider 호출이라 이미 실행된 도구를 재실행하지 않는다(도구 결과는 history에 `tool_result`로 존재). 모델이 continuation에서 새 도구를 부르면 그건 정상 진전이다. blind resume이 아니라 **truncated 마무리의 재생성**이다.
5. **exhaustive**: `stop_reason` typed match는 catch-all `_` 없이 구현해, 새 stop_reason variant 추가 시 컴파일러가 recovery 매핑 누락을 강제한다(§4.1 rule 4·RFC-0042와 동형).

**구현 요약 (2026-07-08, slice 2).** typed 변형으로 관통하며 substring 분류기를 도입하지 않는다:

- `Keeper_internal_error.accept_no_progress_retry_kind`에 `` `Truncated_no_progress `` 추가. guard `accept_rejection_is_truncation_continuation ~reason_kind ~response_shape ~stop_reason`는 `reason_kind=Accept_no_usable_progress && shape∈{Empty,Thinking_only} && stop_reason=Some MaxTokens`일 때 **첫 분기**로 발동(N-of-M 회피 — 모든 MaxTokens empty/thinking을 균일 처리). 기존 세 no-progress guard보다 앞서므로 `tool_effects_seen` 제약 없이 도구-productive 턴도 포착한다.
- `should_retry_no_thinking`이 `` `Truncated_no_progress ``에도 발동(thinking-off continuation). `thinking_was_enabled` 조건이 "이미 off인데 truncate"를 걸러 crash 안전망으로 보낸다.
- `Keeper_error_classify.degraded_retry_reason`에 `Truncated_no_progress` 추가 → `is_completion_contract_violation=false`, rotation cap(cycle 금지)은 다른 no-progress와 동일.
- `Keeper_runtime_failure_route.rotate_class`에 `No_progress_truncated` 추가 — continuation 실패 후 실패 경로에 도달한 truncation은 `Escalate_judgment Contract_violation`이 아니라 `Rotate_now No_progress_truncated`로 라우팅(recovery hint, 별도 telemetry). RFC-0313 W2에서 이 route는 아직 shadow라 crash 누적(`counts_toward_crash`, 위 정정 참조)에 직접 관여하지 않는다.
- cross-runtime `direct_no_progress_retry`는 truncation을 `None`으로 제외(다른 런타임도 동일 truncate) — 복구는 same-runtime thinking-off 전담.
- 테스트: `test_should_retry_no_thinking_gate`에 truncation 진리표 4행, `test_truncation_after_mutation_is_recoverable_continuation`(mad-improver 형태), `test_truncation_classification_only_on_max_tokens`(MaxTokens만 truncation, EndTurn/None은 terminal 유지).

**§4.2와의 관계 / 왜 answer-space 예약이 아닌가.** answer 몫을 예약(thinking을 N토큰으로 cap)하는 것은 fleet-wide 사고 제약이고, 정상 턴의 사고를 매번 제약한다 — #23652에서 기각된 budget-as-control이다. §4.5는 **truncation이 실제 발생한 뒤에만** 1회 발동하는 corrective라 정상 턴을 불변으로 둔다("실패는 관측→대응, 사전 cap 금지"). thinking sub-budget 예약은 명시적 non-goal이다. §4.2(preventive ceiling)는 §9에서 flash에 부적합하다고 re-scope됐고, §4.5는 그와 독립적인 corrective arm이다.

## 5. 인용 RFC 경계

| 항목 | 소유 RFC | 우리 관계 |
|---|---|---|
| accept 판정 (`No_usable_progress`) | RFC-0222 / RFC-0262 | 소비만. 재정의 금지 |
| reroute seam·ordering·visibility | RFC-0265 | seam 재사용, trigger만 신규 |
| provider-failure failover | RFC-0207 Part B / RFC-0260 | trigger 구분 (성공응답+accept실패 ≠ provider error) |
| mid-turn watchdog / progress | RFC-0012 | 공존, progress 신호 emit |
| recovery escalation·N-of-M | RFC-0082 | typed closed-sum 강제 원칙 상속 |
| turn semantics 경계 | RFC-0136 | budget=ceiling, active 아님 |
| typed terminal reason | RFC-0042 | 이미 typed `Accept_rejected{reason}` 소비, string 분류기 금지 |

## 6. Workaround Guards (CLAUDE.md 워크어라운드 거부 기준 대응)

후속 PR이 이 RFC를 *합리적 선례*로 학습할 때 워크어라운드로 흐르지 않도록 명시한다.

1. **budget cap = root prevention, retry ≠ symptom suppression.** thinking_only는 provider 행위(무한 thinking)다. budget ceiling은 그 root를 제거한다 — parse-only(소비자 0)였던 죽은 설정을 enforce로 전환하는 것이지 새 cap/cooldown 추가가 아니다.
2. **retry는 cooldown loop가 아니다.** 같은 runtime에 변화 없이 재진입하면 워크어라운드(cap/cooldown)다. 우리 retry는 `enable_thinking=false`로 **request shape를 결정론적으로 변경**한 단일 시도다. shape 변경 없는 재시도는 이 RFC가 금지한다.
3. **telemetry-as-fix 아님.** recovery arm은 terminal outcome을 바꾼다(usable 턴 전달 또는 typed terminal). `No_usable_progress`를 단지 count/log하지 않는다.
4. **auto-fill 금지.** accept를 통과시키려 progress를 합성/조작하지 않는다(RFC-0222 §3.4). 재시도는 실제 재실행이다.
5. **N-of-M 금지.** recovery_action을 typed closed-sum으로 정의해 모든 dispatch site를 컴파일 타임 강제. 한 site만 패치하고 나머지 `_ ->` 금지.
6. **context-pressure와 budget 원인 혼동 금지.** tool-heavy context가 원인일 수 있는 사례는 recovery arm의 근거이고, parse-only `max_thinking_budget`은 별도 preventive bug다. 두 arm 중 하나가 다른 하나의 증거를 대체하지 않는다.

## 7. 검증 / 구현 단계

- **PR-1 (recovery arm)**: `keeper_turn_driver_try_runtime.ml` accept-rejected 분기에 `recovery_action` typed variant + 단일 bounded recovery. RFC-0265 seam 재사용(reroute), RFC-0012 progress 신호 emit. 테스트: thinking_only 거부 → `Retry_no_thinking` → 성공, 재거부 → `Reroute_tool_reliable`, 후보 없음/재거부 → `Terminal_no_usable_progress <reason>` 단위 테스트. `dune build --root .` 전체 green.
- **PR-2 (budget wiring)**: `max_thinking_budget` producer+consumer 동시 wiring(`runtime_inference` `thinking_budget=Some n`, `worker_oas` `with_thinking_budget n`). per-runtime config, incapable no-op. 라운드트립 테스트(설정값 → request에 반영), `None`이면 field 생략, provider가 budget을 무시해도 synthetic truncation 없이 accept/recovery로 흐르는 테스트. flash·qwen3.5:397b 같은 thinking-support runtime에서 ceiling 적용 확인.
- **즉효 완화 (이 RFC와 독립, 이미 적용)**: tool-heavy 키퍼(issue_king/qa-king)를 flash default에서 tool-reliable runtime(`qwen3.5:397b`)으로 명시 라우팅. recovery arm이 랜딩되기 전까지의 운영 완화.
- **TLA+ (선택)**: recovery_action FSM을 `BugAction`(거부 후 무한 retry / shape 미변경 재시도)으로 모델링해 bounded-recovery invariant 검증.

## 8. 미해결 / open questions

- recovery retry의 budget 회계를 `autonomous_max_turns_per_call`에 포함할지 별도 ceiling으로 격리할지는 PR-1에서 측정 후 결정.
- `Reroute_tool_reliable`의 "tool-reliable" 판정 기준: capability 선언(`tools-support`)은 신뢰 불가(이 RFC의 동기)이므로, 라이브 tool-call 성공률 메트릭(keeper×runtime별 `thinking_chars` 분포 포함)을 별도 진단 축으로 수집해야 정확한 후보 선택이 가능하다. 초기 구현은 config 선언 순서(media_failover 류)로 시작.
- RFC number allocation: `.next-number=0272`는 RFC-0270(CI Gate merge guard)와 이 RFC-0271이 모두 배정됐기 때문이다. RFC-0271은 RFC-0270에 runtime/design dependency를 갖지 않는다.

## 9. Implementation status & diagnosis refresh (2026-07-08)

> Verified against `origin/main` @ current HEAD. RFC-0271's original §3 diagnosis
> ("recovery arm 0", `keeper_turn_driver_try_runtime.ml:196-212`) predates the
> current tree and is partially stale — the reroute arm has since landed.

### What already exists on current main (not this RFC's work)

- The accept rejection is already typed as `Thinking_only_no_progress` /
  `Empty_no_progress` / `Read_only_no_progress`
  (`Keeper_internal_error.accept_no_progress_retry_kind`).
- The **reroute arm** (§4.1 rule 2 — `Reroute_tool_reliable`) is already
  implemented: `accept_rejected_result_should_try_next` +
  `checkpoint_for_accept_rejected_retry` route a no-progress rejection to the next
  runtime candidate. This is the "failover works" behavior the live diagnosis
  observed (it just costs a full-turn re-run on a more expensive lane).

### What the first implementation PR does (§4.1 rule 1 — the remaining gap)

- **`Retry_no_thinking`**: a `Thinking_only_no_progress` rejection on a
  thinking-enabled attempt now gets ONE same-candidate retry with thinking forced
  off (new `?enable_thinking_override` on `run_try_provider`) BEFORE the existing
  reroute. Bounded to once per turn (`recovered_no_thinking`); emits a fresh
  provider-attempt-started so the RFC-0012 watchdog sees progress (§4.3). The
  decision is a pure `should_retry_no_thinking` gate (unit-tested truth table).

### Deferred / re-scoped

- **§4.2 thinking-budget wiring does NOT fit the observed `deepseek-v4-flash`
  case.** flash declares `thinking-control-format = "reasoning-effort"`
  (`config/runtime.toml`) and has no `max_thinking_budget`, so a token-budget
  ceiling (`with_thinking_budget n`) is the wrong control surface. A flash
  preventive would need a **reasoning-effort cap**, a separate mechanism outside
  §4.2's token-budget scope — a follow-up, not this arm. §4.2 remains valid for
  token-budget runtimes (Anthropic-style).

### 2026-07-09 diagnosis — mad-improver mutating-turn truncation collapse (§4.5의 근거)

6-축 deep-dive(keeper `mad-improver` / `runpod_mtp.qwen36-35b-a3b-mtp`, extended-thinking)로 확인한 인과 사슬. 모두 정적 소스 근거(High); 런타임 재현은 미수행.

- **출력 예산 = 16,384 (thinking·answer 공유, answer 몫 예약 0).** thinking runtime resolved `max_tokens = min(ceiling, 32768) = min(16384, 32768) = 16384` (`lib/runtime/runtime_inference.ml:55-61`). ceiling 16384는 `oas-models.toml`이 `max_output_tokens` 미지정 → base preset `openai_chat`의 `Some 16_384` 상속(`oas capabilities.ml:396-399`, `:961-969`). 주석(`runtime_inference.ml:18-30`): "answer is not carved out of a thinking allotment." context 27%(35.6k/131.1k)는 무관 — 131072는 **input** window, 16384는 별개 **output** cap.
- **truncation → empty.** 도구-heavy 턴의 fat 마무리 라운드에서 사고가 16384를 소진 → answer ~0 → `stop_reason=max_tokens`, `content_blocks=0`.
- **오분류 (진짜 결함).** accept가 마무리 응답 블록만 검사(`has_deliverable_content`, `keeper_tool_response.ml:35-44`), `stop_reason` 무시 → `No_usable_progress`. 턴의 mutating 도구 작업(side effect 이미 disk에 적용)은 progress로 인정 안 됨, rollback/ receipt 없음.
- **recovery 0.** mutating+Empty가 세 retry kind에 모두 불일치(전부 `tool_effects_seen=[]`/read-only 요구) → catch-all `None` (`keeper_internal_error.ml:922-951`). 단일 candidate면 reroute도 없음(`is_last=true`).
- **crash → Dead.** non-auto-recoverable → `counts_toward_crash=true` → 매 실패 `increment_turn_failures` (`keeper_unified_turn_failure.ml:48-56`); count ≥ `keeper_max_turn_failures`(기본 10) → `raise Keeper_registry.Keeper_fiber_crash` → supervisor restart(backoff) → `restart_count ≥ max_restarts` → **Dead + task 반환** (`keeper_supervisor.ml:291-294`). production `Pacing_enforce`라 RFC-0313 W3 auto-pause는 dead code = soft-park 안전망 없음. `keeper_failure_circuit_breaker`는 이 경로와 무관(per-tool-call 전용, trip해도 실행 불정지).
- **결론.** 방아쇠는 예산(16384 공유·미예약)이지만 **진짜 결함은 truncation을 no-progress terminal로 둔갑시키는 accept/classification 계층**이다. §4.5가 이를 corrective로 닫는다 — budget을 건드리지 않고, 도구 작업을 인정하고, crash-loop를 끊는다. tool volume은 count 무제한(`max_turns=0` 센티넬)이나 이는 enabler이지 root가 아니다.

**미확인 (재확인 필요):** `thinking_support=Some true`는 증상에서 역추론 — 배포 `runtime.toml` 바인딩이 tree에 없어 config로 미확인. thinking OFF면 예산이 fallback `8192`로 바뀐다. `keeper_max_turn_failures`(10)/`pacing_mode`(enforce)/`supervisor_max_restarts` 기본값의 배포 override 여부 미확인.
