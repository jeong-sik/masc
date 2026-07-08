# RFC-0271 — accept-rejected (No_usable_progress) 키퍼 턴의 in-turn recovery arm + thinking-budget ceiling enforcement

| | |
|---|---|
| Status | Draft |
| Subsystem | `lib/keeper/keeper_turn_driver_try_runtime`, `lib/runtime/runtime_inference`, `lib/worker_oas`, `lib/runtime/runtime_toml` |
| Related | RFC-0222 / RFC-0262 (accept verdict 소유), RFC-0265 (reroute seam), RFC-0207 Part B / RFC-0260 (provider-failure failover), RFC-0012 (mid-turn watchdog), RFC-0082 (recovery escalation·N-of-M 원칙), RFC-0136 (turn semantics 경계), RFC-0042 (typed closure) |
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
