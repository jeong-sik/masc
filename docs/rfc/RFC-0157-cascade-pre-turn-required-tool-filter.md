---
rfc: "0157"
title: "Cascade pre-turn required-tool filter — provider capability boundary"
status: Active
created: 2026-05-21
updated: 2026-05-21
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0042", "0088", "0097", "0127", "0148", "0153", "0154"]
implementation_prs: []
---

# RFC-0157 — Cascade pre-turn required-tool filter

## §0 TL;DR

`try_cascade` 는 현재 candidate 가 *required action* (예: 특정 도구 호출 강제) 을 만족할 수 있는지 확인하지 않고 `Agent.run` 까지 진입한다. 결과는 provider 가 `tool_required` / `tool_choice` 를 반환하지 못해 사후에 detected 되는 `required_tool_contract_violation` (typed) — `lib/keeper/keeper_error_classify.ml::is_required_tool_contract_violation` 가 분류하고, cascade rotation classifier `lib/cascade/cascade_attempt_fsm.ml::fallback_class_required_tool_contract_violation` 가 cascade 진행 결정에 사용한다. 본 RFC 는 turn 진입 *이전* `Provider_capability.can_satisfy_required_action` 으로 사전 필터링하여 violation 발생 자체를 차단하고, 필터된 candidate 를 operator-visible manifest 의 `phase = "pre_dispatch_blocked"` lane (§4.1) 으로 노출한다.

핵심 제약: 사전 필터는 **closed-sum typed extension** 으로 구현한다 — string classifier 가 아니다. 본 RFC 가 신규 도입하는 카운터는 visibility 보조 신호이며 fix 자체가 아니다 (cf. RFC-0088, software-development.md §1 텔레메트리-as-fix). PR #17046 (post-dispatch recovery, 사후 회복) 은 본 RFC scope 밖이며 보완 관계로 유지.

목표 (Phase C 완료 후 24h sustained): cascade attempts 중 `required_tool_contract_violation` 분류 비율이 사전 필터 도입 전 baseline 대비 87% 이상 감소. 정량 수치는 Phase A wiring 시 baseline 측정 후 확정.

## §1 Motivation

### 1.1 정성적 motivation

현재 코드베이스에 사전 필터 도입 전 baseline 을 측정하는 *전용 카운터* 는 없다. 가장 가까운 typed 신호는 다음 세 가지이며, 모두 *사후* 분류 신호다:

| 신호 | 위치 | 의미 |
|---|---|---|
| `Keeper_error_classify.is_required_tool_contract_violation` | `lib/keeper/keeper_error_classify.ml::is_required_tool_contract_violation` | sdk_error 가 required-tool 미충족 클래스인지 분류 |
| `fallback_class_required_tool_contract_violation` (`"required_tool_contract_violation"`) | `lib/cascade/cascade_attempt_fsm.ml::fallback_class_required_tool_contract_violation` | cascade rotation 분류 라벨 |
| `should_auto_pause_required_tool_contract_violation` | `lib/keeper/keeper_unified_turn_types.ml::should_auto_pause_required_tool_contract_violation` | 반복 발생 시 keeper turn auto-pause 트리거 |

세 신호 모두 `Agent.run` *이후* call path 에서 분류된다. 즉 candidate 가 required-tool 을 만족할 수 없음을 알면서도 매번 dispatch → fail → cascade rotation 비용을 지불하고 있다. 2026-05-17 cascade tier-group misroute 사고 (`nickNcave` keeper FAILED) 가 직접 사례 — `routes.tool_required → tier-group.strict_tool_candidates → provider-k cloud` 가 `keeper_shell/tool_execute` inline materialize 실패로 매 cascade 반복.

사용자 보고: "required-tool 을 못 만족하면 그 candidate 를 *애초에* 시도하지 말아야 한다."

TODO (Phase A wiring 직전): `cascade_pre_dispatch_required_tool_filtered` (§4.2) baseline 측정 카운터를 먼저 emit. 24h 데이터 확보 후 §7 acceptance threshold 를 정량 수치로 갱신.

### 1.2 현재 코드 흐름 — fail-after-dispatch

`lib/keeper/keeper_turn_driver.ml::try_cascade` 에서 `try_cascade` 가 선언되며 (`let rec try_cascade ?(on_success = ...) ?resume_checkpoint ?per_provider_timeout_s remaining last_err`), 본체는 candidate 단위 loop 를 형성한다 (verify line at PR time). loop 한 iteration 의 실제 단계는 (순서대로):

1. `lib/keeper/keeper_turn_driver.ml::try_cascade::Eio_guard.fair_yield call` — scheduler-fair 보장
2. `Cascade_runtime_candidate.tier_id` / `first_health_cooldown` 조회
3. health/cooldown 게이트 — `should_skip_health_cooldown` 분기, fail-open 시 WARN 후 통과
4. `lib/keeper/keeper_turn_driver.ml::try_cascade::acquire_client_capacity_slot call` (declared at `lib/keeper/keeper_turn_driver.ml::acquire_client_capacity_slot`) — 클라이언트 capacity semaphore 획득
5. provider attempt — `Agent.run` 등 실 dispatch
6. 결과 분류 — `lib/keeper/keeper_turn_driver.ml::try_cascade::sdk_error_is_required_tool_contract_violation call` 가 사후에 발화 (try_cascade 본체 + post-attempt branch 두 사이트)

problem: 단계 5 의 dispatch 가 cost 의 대부분 (네트워크 RTT, provider state, token spend) 을 이미 발생시킨 뒤에야 단계 6 에서 violation 이 드러난다. 단계 3 (health) 과 단계 4 (capacity slot) 사이에 *capability* 게이트가 없다 — required-tool 충족 가능성은 health 와 무관한 결정적 조건이지만 현재는 표현되지 않는다.

Current origin/main anchors checked on 2026-05-21:

- `lib/keeper/keeper_turn_driver.ml:881` defines the cascade loop boundary.
- `lib/keeper/keeper_turn_driver.ml:1016` acquires the client capacity slot after
  preflight work, which is the resource this RFC must avoid occupying for
  impossible candidates.
- `lib/keeper/keeper_error_classify.ml:154` is the late, post-dispatch
  required-tool violation classifier this RFC moves ahead of dispatch.
- `lib/keeper/keeper_agent_tool_surface.mli:160` exposes the satisfying-tools
  surface that can seed the capability snapshot.

```ocaml
(* Desired Phase A order, before provider dispatch. *)
fair_yield ();
pre_dispatch_required_tool_filter candidate required_tools;
health_cooldown_gate candidate;
acquire_client_capacity_slot candidate;
dispatch candidate
```

### 1.3 이미 존재하는 typed 신호 (재사용 가능)

| 신호 | 위치 | 현 용도 | RFC 활용 |
|---|---|---|---|
| `required_tool_candidate_names : string list` | `lib/keeper/keeper_agent_tool_surface.mli::required_tool_candidate_names` (record field, both record types) | turn 입력 surface 에 도구 후보 이름 전달 | 사전 필터의 *입력* |
| OAS `satisfying_tools` | `lib/keeper/keeper_agent_tool_surface.mli::satisfying_tools_for_turn` / `lib/keeper/keeper_agent_tool_surface.ml::satisfying_tools_for_turn` | OAS manifest 가 어떤 tool 이 contract 를 만족하는지 표기 | 사전 필터의 *제약* |
| `require_tool_choice_support : bool` | `lib/keeper/keeper_turn_driver.ml::require_tool_choice_support` (named arg, multiple call sites) | provider 가 tool_choice API 를 지원하는지 | capability 의 *전제* |

이미 세 신호가 turn 진입 *시점* 에 typed 으로 존재한다. 부족한 것은 셋을 *결합하여* candidate 를 사전 거부하는 boundary 함수와, 그 결과를 manifest 에 lane 으로 노출하는 surface.

### 1.4 사전 필터가 부재한 직접 비용

- provider RTT 낭비 (특히 Provider-K/Provider-C cloud 의 cold start)
- token budget 낭비 (system + tool schema prompt 가 매 candidate 마다 재전송)
- cascade clock 낭비 → RFC-0153 의 `max_execution_time_s 300s` budget 잠식
- operator 가 "왜 이 candidate 가 시도됐는가" 를 trace 할 수 없음 (manifest 가 dispatch 결과만 기록)

## §2 Non-goals

명시적 제외:

1. **Post-dispatch recovery** — PR #17046 (사후 검출 후 turn 재시도) 의 scope. 본 RFC 는 *사전 회피* 이며 사후 recovery 와 직교한다. 둘 다 필요.
2. **OAS provider-side filtering** — provider (Provider-D, Provider-A, Provider-K, ...) 가 내부적으로 `tool_required` 를 무시하는 케이스. MASC 통제 밖. 본 RFC 는 MASC 가 *알 수 있는 capability 정보* 로만 필터.
3. **Required-tool semantics 확장** — 현재 contract (단순 도구 이름 매칭) 를 유지. 정규식/패턴/wildcard 매칭은 별도 RFC.
4. **Cascade-level concurrency** — RFC-0153 Phase B scope. 본 RFC 는 순차 cascade 안에서 candidate 단위 필터.
5. **Provider downtime detection** — RFC-0127 scope. health/cooldown 체크는 본 RFC 게이트 *후* 그대로 유지.

## §3 Design

### 3.1 새로운 typed boundary

```ocaml
(* lib/cascade/provider_capability.mli — NEW MODULE *)

(** A candidate's ability to satisfy a required-tool action,
    answered at cascade boundary before Agent.run dispatch. *)

type t = {
  provider_name : string ;
  satisfying_tools_snapshot : string list ;
    (** Tool names this candidate's tool surface exposes
        at the moment of snapshot. Sourced from OAS satisfying_tools
        when available; empty list when unknown. *)
  tool_choice_support : bool ;
    (** Mirrors require_tool_choice_support
        (lib/keeper/keeper_turn_driver.ml::require_tool_choice_support). *)
}

(** Pre-dispatch filter result.
    - [Some true]  : candidate definitely can satisfy required_tools
    - [Some false] : candidate definitely cannot — skip and record
    - [None]       : capability unknown — pass through (do not pre-filter)

    The [None] case is load-bearing: it preserves current behavior
    for providers without capability snapshot, avoiding false positives
    when a provider could satisfy a required tool via dynamic discovery. *)
val can_satisfy_required_action :
  t -> required_tools:string list -> bool option

(** SSOT helper used by [try_cascade]. Single call site for the entire
    filter loop — avoids N-of-M anti-pattern (§5). *)
val filter_candidates_for_required_tools :
  t list ->
  required_tools:string list ->
  passed:(t list) ->
  filtered:((t * string list) list)  (* (candidate, missing_tools) *)
  -> t list * (t * string list) list
```

### 3.2 NEW module — `Cascade_candidate_skip_reason`

`Cascade_preflight_state` (lib/cascade/cascade_preflight_state.mli) 는 *log-level cadence* 모듈이다 — module docstring 명시 ("Routing semantics are preserved: the disabled list is advisory. Callers may still attempt the provider; this module only changes the {e log-level cadence}, not routing"). 실제 reason 변형도 health 전용이다: `Health_check_failed_repeatedly | Permanent_unhealthy | Transient_unhealthy | Rate_limited_long_window`.

본 RFC 는 *routing* 결정 (사전 skip) 을 도입하므로 cadence-only 모듈을 widening 하는 대신 **신규 모듈**을 추가한다 — 두 관심사를 분리 유지하여 cadence 모듈이 의도치 않게 routing semantics 를 흡수하는 것을 방지.

```ocaml
(* lib/cascade/cascade_candidate_skip_reason.mli — NEW MODULE *)

(** Routing-affecting reason for skipping a cascade candidate
    before dispatch. Distinct from [Cascade_preflight_state.reason]
    (which is health log-cadence only, advisory). *)
type t =
  | Required_tool_unsupported of {
      missing : string list ;
        (** Required tools the candidate cannot satisfy
            per Provider_capability snapshot. *)
    }
  (* Future arms (closed-sum, add via PR + exhaustive-match cascade): *)
  (* | Capability_profile_mismatch of { profile : string ; ... } *)
  (* | Policy_blocked of { rule : string ; ... } *)

val to_manifest_tag : t -> string
(** Stable wire tag for manifest decision lane lookup (§4.1). *)
```

closed-sum; OCaml exhaustive `match` 가 모든 caller 에서 새 arm 처리를 강제한다 — silent fall-through 없음. `Cascade_preflight_state` 는 변경하지 않는다.

### 3.3 Wire 지점 — `try_cascade` boundary

대상: `lib/keeper/keeper_turn_driver.ml::try_cascade` 함수. 본체는 candidate loop 안에서 `Eio_guard.fair_yield ()` call, health/cooldown 게이트, 그리고 `acquire_client_capacity_slot` (declared at `lib/keeper/keeper_turn_driver.ml::acquire_client_capacity_slot`, called inside `try_cascade`) 의 capacity semaphore 획득 후 provider dispatch 순서로 진행. 사전 필터는 `fair_yield` 직후, health 게이트 *앞* 에 위치한다 (verify exact insertion line at PR time).

```ocaml
| candidate :: rest ->
    Eio_guard.fair_yield ();  (* lib/keeper/keeper_turn_driver.ml::try_cascade::Eio_guard.fair_yield call — preserved *)
    (* NEW: §3.1 의 사전 필터. health/cooldown 게이트 앞.
       이유: capability mismatch 는 health 와 무관한 결정적 조건이며,
       acquire_client_capacity_slot 보다 저비용. *)
    (match Provider_capability.can_satisfy_required_action
             (snapshot_of candidate) ~required_tools with
     | Some false ->
         let missing = compute_missing candidate required_tools in
         let skip_reason =
           Cascade_candidate_skip_reason.Required_tool_unsupported { missing }
         in
         Manifest.record_pre_dispatch_blocked
           ~candidate:(Cascade_runtime_candidate.provider_label candidate)
           ~skip_reason ;
         Metrics.incr_with_labels
           "cascade_pre_dispatch_required_tool_filtered"
           [("provider", Cascade_runtime_candidate.provider_label candidate) ;
            ("missing_count", string_of_int (List.length missing))] ;
         try_cascade ~on_success ?resume_checkpoint ?per_provider_timeout_s
           rest last_err
     | Some true | None ->
         (* existing path: health/cooldown → acquire_client_capacity_slot
            → provider attempt. Downstream of the fair_yield call,
            unchanged. *) ...)
```

순서가 중요: 사전 필터를 health/cooldown *앞* 에 두는 이유는 (a) 결정적이고 저비용이며, (b) `acquire_client_capacity_slot` semaphore 를 capability-fail candidate 가 잠시라도 점유하지 않도록 하기 위함, (c) `Cascade_preflight_state` 의 health-cadence 신호를 capability mismatch 로 오염시키지 않기 위함.

### 3.4 Secondary site

`lib/keeper/keeper_agent_run.ml::required_tool_names` (OAS manifest emission block, `runtime_manifest_required_tool_names` named arg) — `required_tool_names` 가 이미 OAS manifest 로 전달되는 자리. 본 RFC 는 *cascade* 진입 이전 필터이므로 이 사이트는 변경 안 함. 단, OAS manifest 가 `satisfying_tools` 를 반환하는 시점이 `Provider_capability.snapshot_of` 의 *데이터 소스* 가 된다 — 캡처/저장 경로는 Phase B 에서 정의.

### 3.5 "all candidates filtered" 처리

모든 candidate 가 `Some false` 로 필터되면:

```ocaml
| [] when any_filtered_for_required_tool ->
    Error (No_providers_satisfy_required_tools {
      required_tools ;
      attempted_candidates_with_missing : (string * string list) list ;
    })
```

명시적 typed error 로 propagate 한다. 절대 silent skip 아님. Keeper turn 은 fail 하며 operator 는 manifest 에서 "X candidate 가 Y tool 을 미지원" 을 본다.

이 보호는 §5 의 텔레메트리-as-fix 반복 방지에 결정적이다: 필터가 cascade 를 *조용히* 비우면, 단순 카운터 증가 + 빈 cascade exhausted = visibility 보강 패턴 자체가 됨. typed error 로 visibility 와 fix 를 분리.

## §4 Observability

### 4.1 Manifest decision lane (NEW)

**현 상태 (검증)**: keeper manifest 의 decision 표면은 `lib/keeper/keeper_unified_turn_phase_plan.ml::turn_plan_manifest_decision` (`: turn_plan -> Yojson.Safe.t`) 와 `lib/keeper/keeper_unified_turn_types.ml::turn_event_bus_manifest_decision` — 둘 다 **`Yojson.Safe.t` 를 반환하는 함수**이며 typed sum 이 아니다. 본문은 `\`Assoc [ "phase", ...; "reason", \`String ...; "executable", \`Bool ... ]` 형태로 phase/reason/executable 필드를 emit.

**본 RFC 의 추가**: 사전 필터 결과를 동일 JSON 표면에 새 phase 값으로 추가. typed sum 으로 lift 하는 것은 *별도 작업* (후속 RFC 후보 — 모든 caller 의 Yojson 직접 조립을 closed-sum 으로 옮기는 범위) 으로 분리. 본 RFC 는 현 JSON 구조 위에서 stable wire tag 를 정의하는 데 그친다.

JSON 스키마 (추가 분):

```json
{
  "phase": "pre_dispatch_blocked",
  "reason": "required_tool_unsupported",
  "executable": false,
  "skip_reason": {
    "kind": "required_tool_unsupported",
    "candidate": "<provider_or_runtime_candidate_label>",
    "missing": ["<tool_name>", ...]
  }
}
```

- `phase = "pre_dispatch_blocked"` 는 신규 phase 값. 기존 `phase` 값 (예: dispatch / skipped / cancelled / error 대응) 과 직교.
- `skip_reason.kind` 는 `Cascade_candidate_skip_reason.to_manifest_tag` (§3.2) 가 emit — 신규 routing skip reason 추가 시 단일 mapping 함수로 wire 일관성 강제.
- `candidate` 는 `Cascade_runtime_candidate.provider_label` 결과 (라우팅 식별자, secret 미포함).

operator dashboard 는 `phase = "pre_dispatch_blocked"` lookup → `skip_reason.kind` 별 렌더. backend 가 한 번 typed 으로 분류한 결과를 stable JSON tag 로 직렬화하고, frontend 는 lookup-only 로 렌더 (RFC-0154 system error class SSOT 와 동일 원칙).

**Follow-up (별도 RFC 후보)**: `turn_plan_manifest_decision` 의 반환 타입을 `Yojson.Safe.t` 에서 closed-sum `manifest_decision` 으로 lift. 본 RFC scope 가 아니지만, 그 RFC 가 머지되면 본 RFC 가 정의한 JSON 스키마는 typed sum 의 한 arm 으로 자연 흡수된다.

### 4.2 Counter (NEW, visibility only)

```
cascade_pre_dispatch_required_tool_filtered{
  provider="<provider_name>",
  missing_count="<int>"
}
```

용도: Phase B/C 진행 중 *얼마나 잘 필터되고 있는지* 측정. 본 카운터는 **fix 가 아니다** — fix 는 `Provider_capability` 의 사전 필터 자체이며, 카운터는 그 효과를 측정한다 (§5 self-check 참조).

### 4.3 Target signal (REDUCED)

`Keeper_error_classify.is_required_tool_contract_violation` 가 분류하는 사후 violation 비율 — Phase A wiring 시 emit 할 baseline 카운터 (예: `required_tool_contract_violation_classified_total`, Phase A PR 에서 명시) 로 측정. 본 typed 분류기 자체는 *제거 대상이 아니다* — provider-side dynamic 변경 (예: tool surface 가 turn 중간에 바뀜) 으로 인한 잔여 violation 은 정당한 신호이므로 0 이 아닌 *낮은 baseline* 이 정상.

### 4.4 Anti-pattern guard

본 RFC 카운터 (`cascade_pre_dispatch_required_tool_filtered`) 는 다음 두 조건을 만족하지 않으면 의미가 없다:

1. Phase A baseline 카운터 (§4.3) 가 *동시에 감소* 한다 (사전 필터가 사후 violation 을 흡수)
2. `cascade_pre_dispatch_required_tool_filtered.sum / phase_A_baseline_violation >= 0.5` — 사전 필터가 baseline violation 의 *과반* 을 흡수해야 의미 있는 boundary 라고 본다. 0.5 는 보수적 floor (절반 미만이면 boundary 의 capability snapshot 이 너무 sparse 한 것이므로 Phase B 의 snapshot capture 경로를 먼저 보강) 이며, 충분한 데이터 축적 후 Phase D 에서 상향 검토.

두 조건이 깨지면 RFC 구현이 잘못된 것이므로 PR rollback. counter 증가만 보고 "잘 동작한다" 결론 금지.

## §5 Workaround rejection self-check

`software-development.md` §워크어라운드 거부 기준 체크리스트 7항목 대조:

| # | 시그니처 | 본 RFC 해당? | 근거 |
|---|---|---|---|
| 1 | "makes X visible" / "instrument Y" only (fix 없음) | **No** | fix = `Provider_capability` 사전 필터 (실제 dispatch 회피). 카운터는 §4.4 anti-pattern guard 로 단순 visibility 신호임을 명시 |
| 2 | string/substring/prefix 분류기 추가 | **No** | `can_satisfy_required_action` 은 `bool option` (closed). 분류는 typed sum `Required_tool_unsupported of { missing }` |
| 3 | "PR #N only fixed K of M sites" | **No** | SSOT helper `filter_candidates_for_required_tools` — 단일 호출 지점 (try_cascade) |
| 4 | catch-all `_ ->` 추가 | **No** | `Cascade_preflight_state.reason` 은 closed-sum, exhaustive match. 새 arm 추가 시 컴파일러가 모든 caller 처리 강제 |
| 5 | cap/cooldown/dedup/repair (대체 RFC 없음) | **No** | RFC-0153 (cascade backpressure) 와 RFC-0127 (provider fast-fail) 와 명시적 분업. 본 RFC 는 capability boundary |
| 6 | test backdoor 노출 | **No** | 신규 typed API 만 추가; `set_X_for_test` 없음 |
| 7 | 같은 typo/off-by-one 을 N 사이트에 N 번 fix (codemod 미수행) | **No** | 단일 boundary 함수 + manifest lane 1개. cascade 가 유일 호출 지점 |

자가 평가 결과: 7/7 통과. 본 RFC 는 type-extension (closed sum + record) 이며 텔레메트리-as-fix 패턴 아님.

### 5.1 None-default 의 위험

`can_satisfy_required_action` 이 `Some false` 가 아닌 `None` 을 반환할 때 candidate 가 통과한다 (§3.1). 이것은 `software-development.md` §2 "Unknown → Permissive Default" 안티패턴과 *유사하게 보일 수 있다*. 차이:

- 안티패턴 §2 의 wildcard 는 unknown 입력을 *무조건 동작* 으로 매핑하여 silent 한다.
- 본 RFC 의 `None` 은 unknown 을 *현 동작 유지 + manifest 에 unknown 명시* 로 매핑한다 (§3.3 의 `Some true | None` 분기). 즉 capability 가 *알려진* 경우만 새 boundary 가 작동.
- Phase A 의 의도는 "snapshot 없는 provider 는 변화 없음" — 안전한 점진 도입.

이 차이를 §3.1 docstring 에 explicit 으로 명시하고, manifest 가 *unknown capability* 도 별도 lane (`Pre_dispatch_capability_unknown`) 으로 노출하는 것은 Phase B 이후 선택. Phase A 에서는 manifest 에 새 lane 추가 안 함 — over-instrumentation 회피.

## §6 Migration

| Phase | 작업 | 측정 (falsifiable) |
|---|---|---|
| **A** | `Provider_capability` 모듈 신설. `can_satisfy_required_action` 이 모든 provider 에 대해 `None` 반환 (snapshot 없음). `try_cascade` 에 게이트 wiring 추가 — 실 동작 변화 0. baseline 카운터 `required_tool_contract_violation_classified_total` emit 시작. | (a) unit test green (`None`/`Some true`/`Some false`/`No_providers_satisfy_required_tools` 4 case PASS); (b) baseline 카운터 24h 표본 ≥ 1건 emit 확인; (c) `cascade_pre_dispatch_required_tool_filtered` 24h 합계 = 0 (snapshot 미존재이므로) |
| **B** | 첫 provider (예: Provider-K) 의 capability snapshot 캡처 경로 신설. OAS manifest 의 `satisfying_tools` 가 `Provider_capability.t` 로 흘러가는 wire 추가. snapshot 은 capture 되지만 `can_satisfy_required_action` 은 여전히 `None` 반환 (필터 미작동). | (a) Phase B target provider 중 **최소 1개 provider** 의 manifest 응답에서 `provider_capability.snapshot` 필드가 non-null; (b) 24h 동안 해당 provider 의 snapshot 갱신 횟수 ≥ 1; (c) `cascade_pre_dispatch_required_tool_filtered` 24h 합계 = 0 (필터 미작동 보장) |
| **C** | Phase B provider 에 한해 `can_satisfy_required_action` 이 `Some _` 반환 시작. `cascade_pre_dispatch_required_tool_filtered{provider="provider-k"}` 측정 시작. | 24h sustained 후 §4.4 anti-pattern guard 두 조건 동시 PASS: (a) Phase A baseline 카운터가 Phase A 24h 표본 대비 *감소*; (b) `cascade_pre_dispatch_required_tool_filtered.sum / phase_A_baseline ≥ 0.5` |
| **D** | Phase C 결과가 만족스러우면 나머지 provider 반복. anti-pattern guard 미통과 provider 는 Phase B 로 회귀하여 snapshot 수집 경로 수정. | (a) `providers_with_capability_snapshot / total_active_providers ≥ 0.5`; (b) 24h 합계 `required_tool_contract_violation_classified_total` 가 Phase A baseline 대비 ≥ 50% 감소 (Phase A 절대치 측정 후 수치 정합 검토) |

각 Phase 는 별도 PR. Phase A 가 first commit (메커니즘만, 동작 변화 없음). Phase D 가 완료되면 본 RFC `Implemented` 로 이행.

### 6.1 Rollback 경로

Phase C 이후 Phase A baseline 카운터 (§4.3 `required_tool_contract_violation_classified_total`) 가 *오히려 증가* 하거나 `No_providers_satisfy_required_tools` 가 Phase A baseline 대비 5x 이상 발생하면 해당 provider 의 `can_satisfy_required_action` 을 `None` 반환으로 force-degrade (env flag 또는 config). 모듈 자체는 유지하여 재진입 가능.

## §7 Acceptance criteria

Phase C 완료 후 24h sustained:

1. Phase A 에서 emit 시작한 baseline 카운터 (`required_tool_contract_violation_classified_total`) 가 Phase A 24h 표본 대비 ≥ 50% 감소 (Phase A baseline 측정 후 절대 목표치를 정량 갱신 — TODO)
2. `cascade_pre_dispatch_required_tool_filtered.sum / phase_A_baseline_violation ≥ 0.5` (§4.4)
3. `No_providers_satisfy_required_tools` typed error 가 keeper turn 결과로 명시적으로 발생하는 사례 ≥ 1건 — silent path 가 없음을 증명
4. operator dashboard 에서 `phase = "pre_dispatch_blocked"` lane (§4.1) 이 manifest 응답에 노출되어 lookup 가능

Phase D 완료 후 추가:

5. `providers_with_capability_snapshot / total_active_providers ≥ 0.5` (Phase D 안정화 후 Phase D 산출 데이터로 상향 검토)

## §8 Risks

### 8.1 False-positive filtering

candidate 가 snapshot 시점 이후 *동적으로* 새 tool 을 expose 하는 경우, `can_satisfy_required_action` 이 `Some false` 를 잘못 반환할 수 있다. 영향: 작동 가능한 candidate 가 skip 됨 → cascade exhaust 가능.

완화:
- 기본은 `None` (필터 비활성) — Phase C 의 *명시적* opt-in provider 에 한해서만 `Some false` 발생
- snapshot 데이터의 TTL 명시 (Phase B 에서 정의) — 오래된 snapshot 은 `None` 으로 degrade
- §6.1 rollback 경로

### 8.2 Snapshot capture cost

매 turn 마다 capability snapshot 캡처가 turn 진입 latency 를 증가시킬 위험. Phase B 에서 측정.

완화: snapshot 은 provider 단위 cached, TTL 기반 invalidation. turn-per-snapshot 갱신 안 함.

### 8.3 Manifest 노출 후 operator confusion

새 lane (`phase = "pre_dispatch_blocked"`, `skip_reason.kind = "required_tool_unsupported"`) 이 기존 health/cooldown skip 신호 와 동시에 발생하면 operator 가 "왜 이 candidate 가 두 가지 이유로 skip 됐는가" 혼란.

완화: §3.3 의 순서 보장 — 사전 필터는 health/cooldown *앞* 에서 결정적으로 처리, 한 candidate 는 한 lane 만 진입.

### 8.4 Phase 사이 partial migration drift

Phase B/C 가 long-running 일 때, 일부 provider 만 snapshot 보유, 나머지는 미보유 상태가 장기 지속 가능. 이 자체는 안전 (`None` 은 현 동작) 이지만 operator 가 "왜 이 provider 만 lane 에 안 나오나" 혼란 가능.

완화: dashboard 에 "providers with capability snapshot" 카운트 노출 (Phase B 부수 작업).

## §9 Open questions

### Q1. "All candidates filtered" 정책

`No_providers_satisfy_required_tools` 발생 시 keeper turn 의 동작:

옵션 A: turn 즉시 fail, operator 가 required_tool 요구를 완화하거나 provider 추가
옵션 B: required_tool 제약을 한 단계 relax (예: `tool_choice: required` → `tool_choice: auto`) 하여 재시도
옵션 C: A 가 기본, env flag `MASC_CASCADE_RELAX_ON_NO_CAPABILITY=true` 로 옵트인 B

권장: 옵션 A. 옵션 B 는 "required" 의 의미를 약화시키며 RFC-0148 (sunset 한 fallback) 패턴 재현 위험. 단, 사용자 검토 필요.

### Q2. OAS satisfying_tools 의 권위성

OAS manifest 의 `satisfying_tools` 가 *현재 turn 시점* 의 tool surface 만 반영하는지, *향후 turn* 까지 안정한지 명확하지 않음. 만약 turn 별로 surface 가 바뀐다면 capability snapshot 의 TTL 이 사실상 turn 단위여야 함 — Phase B 의 wire cost 가 증가.

권장: Phase B 시작 시 OAS manifest 코드를 audit, surface 안정성 가정을 명시. 안정하지 않으면 본 RFC 는 cache 가 아닌 *real-time* lookup 으로 재설계.

### Q3. Provider_capability 의 multi-tier 효과

cascade tier-group (RFC-0153 §1.1) 내부에 여러 candidate 가 있을 때, 본 RFC 의 사전 필터가 tier-group *전체* 를 비울 수 있다. 그러면 다음 tier-group 으로 진행 — 이것이 정상 동작이지만, tier-group 수준의 "이 tier-group 은 required_tool 미지원" 텔레메트리가 별도로 필요한지 미정.

권장: Phase C 데이터 수집 후 별도 follow-up. Phase A/B/C 에서는 candidate-level 만.

### Q4. `keeper_tool_policy_blocked` 와의 상호작용

`keeper_tool_policy_blocked` (별도 P0, typed tool surface) 도 사전 차단 패턴. 본 RFC 와 같은 boundary 모듈 (`Provider_capability`) 로 통합 가능한가?

권장: 별도. policy_blocked 는 *허용 정책* (security) 이고 본 RFC 는 *능력 매칭* (capability). 두 boundary 가 의미적으로 다르며 합치면 §1 텔레메트리-as-fix 회귀 위험. 단, 두 boundary 모두 manifest decision lane 으로 노출되어야 한다는 *surface 통일* 은 Phase D 이후 follow-up RFC 후보.

---

## Implementation notes (Phase A 만)

Phase A PR 작업 항목 (참고 — 본 RFC 머지 후 별도 PR):

1. `lib/cascade/provider_capability.ml{,i}` 신설 — `t` record, `can_satisfy_required_action` (모두 `None` 반환), `filter_candidates_for_required_tools` SSOT helper
2. `lib/cascade/cascade_candidate_skip_reason.ml{,i}` 신설 — §3.2 의 routing-affecting skip reason closed-sum + `to_manifest_tag`. `Cascade_preflight_state` 는 *건드리지 않는다* (cadence vs routing 관심사 분리)
3. `lib/keeper/keeper_turn_driver.ml::try_cascade` 본체 (`Eio_guard.fair_yield ()` call 직후, health 게이트 진입 *앞*) 에 §3.3 게이트 wiring — Phase A 에서는 `None` 만 반환되므로 실 동작 변화 없음 (verify exact insertion line at PR time)
4. unit test: `provider_capability_test.ml` 신설 — `None` / `Some true` / `Some false` 세 케이스 + `No_providers_satisfy_required_tools` typed error 발생
5. counter 등록: `cascade_pre_dispatch_required_tool_filtered{provider, missing_count}` (Prometheus 자동 등록 path)

Phase B/C/D 작업은 본 RFC 의 evidence 가 수집된 후 별도 사용자 검토.
