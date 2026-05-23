---
rfc: "0163"
title: "Tier-group capability profile route canonicalization — typed dedup and bypass closure"
status: Draft
created: 2026-05-23
updated: 2026-05-23
author: claude-opus
supersedes: []
superseded_by: null
related: ["0058", "0153", "0157"]
implementation_prs: []
---

# RFC-0163 — Tier-group capability profile route canonicalization

## §0 TL;DR

`cascade_catalog_runtime_resolve.ml` 의 `normalize_declared_name` 와 `profile_lookup` 사이의 auto-normalize 경로가 raw short form (`"strict_tool_candidates"`) 을 `"tier-group.strict_tool_candidates"` 로 silent prefix-prepend 한다. 이것은 RFC-0058 이 정의한 "routes → tier-group" canonical path 를 우회하는 사이드 채널이다 — caller 가 short string 을 직접 던지면 route table 을 통째로 걸러뛴다.

또한 `lib/keeper/keeper_health_probe.ml:73` 의 `contains "strict_tool_candidates"` 문자열 매칭은 typed sum 이 아닌 substring 분류기로, 새로운 capability profile 이름이 추가될 때마다 이 문자열 리스트를 수동 갱신해야 한다.

본 RFC 는 두 경로를 동시에 닫는다:

1. **typed dedup**: `cascade_name` 을 closed-sum `Cascade_name.t` 로 lift 하여 canonical path 와 short form 을 한 타입 안에서 표현. auto-normalize 는 *parser* 에서 한 번, 이후 모든 downstream 은 canonical path 만 본다.
2. **bypass closure**: `normalize_declared_name` 의 fallback auto-prefix 리스트를 제거. short form 은 파싱 시점에 *명시적* 오류로 거부되거나, 정책에 따라 *정확히 하나의* canonical path 로 매핑된다. silent 다중 시도 금지.
3. **string classifier elimination**: `keeper_health_probe.ml` 의 `contains` 기반 분기를 typed error variant 기반으로 교체. 새 capability profile 은 컴파일러가 모든 분기 처리를 강제.

## §1 Motivation

### 1.1 Route table bypass (SSOT 위반)

`lib/cascade/cascade_catalog_runtime_resolve.ml:264-273` (origin/main, 2026-05-23):

```ocaml
let normalized =
  match
    [ trimmed; "tier-group." ^ trimmed; "tier." ^ trimmed ]
    |> List.find_opt (fun candidate ->
           Option.is_some
             (profile_lookup snapshot.profiles candidate))
  with
  | Some candidate -> candidate
  | None -> normalize_declared_name raw_name
```

이 코드의 동작: `"strict_tool_candidates"` 를 입력받으면 `"strict_tool_candidates"`, `"tier-group.strict_tool_candidates"`, `"tier.strict_tool_candidates"` 를 *순차 시도* 하여 첫 match 를 반환. 결과적으로 caller 가 `"strict_tool_candidates"` 라고 던지면 `"tier-group.strict_tool_candidates"` 로 자동 확장되어 동작한다.

문제:

- **SSOT 위반**: `cascade.toml` 의 `[[routes]]` 테이블이 "canonical path 는 `"tier-group.strict_tool_candidates"`" 라고 정의하는데, 코드는 `"strict_tool_candidates"` 도 받아들인다. 같은 의미가 두 가지 wire format 으로 존재.
- **Silent drift**: `cascade.toml` 에서 `"tier-group.strict_tool_candidates"` 를 `"tier.strict_tool_candidates"` 로 옮기면, auto-normalize 는 *여전히* `"strict_tool_candidates"` 를 받아들여 첫 match (`"tier-group"` prefix) 를 반환. operator 가 route table 을 바꿨음에도 실제 동작이 바뀌지 않을 수 있다.
- **Discovery cost**: "이 문자열이 어디에서 유효한가" 를 파악하려면 `profile_lookup` 의 auto-prefix 로직을 추적해야 함. 문자열 값 자첧만으로는 의미를 알 수 없음.

### 1.2 String classifier (안티패턴 §2)

`lib/keeper/keeper_health_probe.ml:65-85`:

```ocaml
else if
    contains "tier_admission"
    || contains "inflight_capacity_full"
    || contains "strict_tool_candidates"
    || contains "tier="
  then Tier_admission_full
```

`contains` 는 문자열 substring match 이다. 새로운 tier admission 관련 신호(예: `"capability_profile_mismatch"`) 가 추가되면 이 문자열 리스트에 수동 추가해야 한다. 컴파일러는 누락을 감지하지 못한다. 실제: RFC-0157 이 도입하는 `"required_tool_unsupported"` 도 여기에 추가되어야 하는데, 현재 코드에는 없다.

### 1.3 Two problems, one root

auto-normalize 와 string classifier 는 표면적으로 다른 파일의 다른 문제처럼 보이지만, **같은 root** 에서 온다: `cascade_name` 이나 `error_message` 가 *raw string* 으로 전달되며, 그 의미가 문자열 조작(string prefix/suffix/containment) 에 의존한다. typed sum 으로 lift 하면 둘 다 해결된다.

## §2 Non-goals

1. **Route table semantics 변경**: `cascade.toml` 의 `[[routes]]` 구조나 tier-group 정의를 바꾸지 않는다. 본 RFC 는 *wire format* 과 *분류기* 만 변경.
2. **Capability profile 의미 확장**: 현재 `"strict_tool_candidates"`, `"tool_strict"` 등의 의미는 유지. 새 profile 을 추가하는 것은 별도 RFC.
3. **Health probe 전체 rewrite**: `keeper_health_probe.ml` 의 다른 분기(`Client_capacity_full`, `Provider_capacity` 등) 는 본 RFC scope 밖. 단, `Tier_admission_full` 분기만 typed 로 교체.
4. **Backward-compatible short form 지원**: Phase A 부터 short form 은 *파싱 시점 오류* 로 처리. migration window 없음. (근거: 현재 short form 을 쓰는 caller 는 `cascade.toml` 낸부의 MASC 코드로, 한 PR 에서 모두 교체 가능.)

## §3 Design

### 3.1 Typed cascade name — `Cascade_name.t`

```ocaml
(* lib/cascade/cascade_name.mli — NEW MODULE *)

(** Canonical cascade name with no silent auto-normalization.
    All downstream consumers see only the canonical form. *)

type t = private string
(** Opaque — constructor enforces canonical prefix. *)

val of_string : string -> (t, [ `Invalid_prefix | `Empty ]) result
(** Parse a raw cascade name.
    - Accepts: "tier-group.X", "tier.X", "route.X" (canonical prefixes)
    - Rejects: bare "X" without prefix -> [`Invalid_prefix]
    - Rejects: empty string -> [`Empty] *)

val of_string_exn : string -> t
(** Development-time convenience. Raises [Failure] on invalid input. *)

val to_string : t -> string
(** Extract canonical string for profile_lookup, manifest emission,
    Prometheus labels. *)

val pp : Format.formatter -> t -> unit
```

`private string` 이므로 기존 `string` 을 요구하는 API 와의 호환은 `to_string` 한 번으로 해결. 신규 API 는 `t` 를 직접 받는다.

### 3.2 Parser integration

`cascade_catalog_runtime_resolve.ml` 의 `profile_lookup` 호출 전단계를 수정:

```ocaml
(* BEFORE (current) *)
let normalized =
  match
    [ trimmed; "tier-group." ^ trimmed; "tier." ^ trimmed ]
    |> List.find_opt (...)
  with
  | Some candidate -> candidate
  | None -> normalize_declared_name raw_name

(* AFTER (Phase A) *)
match Cascade_name.of_string raw_name with
| Ok name ->
    let canonical = Cascade_name.to_string name in
    (match profile_lookup snapshot.profiles canonical with
     | Some profile -> Ok (snapshot, canonical, profile)
     | None -> Error (Printf.sprintf "unknown cascade_name %S" canonical))
| Error `Invalid_prefix ->
    Error (Printf.sprintf
             "cascade_name %S lacks required prefix (tier-group|tier|route)"
             raw_name)
| Error `Empty ->
    Error "cascade_name is empty"
```

auto-prefix 리스트 `[trimmed; "tier-group." ^ trimmed; ...]` 와 `List.find_opt` 제거. 단일 시도, 명시적 실패.

### 3.3 Health probe typed classification

`lib/keeper/keeper_health_probe.ml` 의 `Tier_admission_full` 분기를 typed variant 기반으로 교체:

```ocaml
(* BEFORE *)
else if
    contains "tier_admission"
    || contains "inflight_capacity_full"
    || contains "strict_tool_candidates"
    || contains "tier="
  then Tier_admission_full

(* AFTER *)
else if is_tier_admission_error err then Tier_admission_full
```

`is_tier_admission_error` 의 구현은 typed error variant 를 match:

```ocaml
(* lib/keeper/keeper_health_probe.ml — helper *)
let is_tier_admission_error (err : Keeper_error_classify.error_class) =
  match err with
  | Tier_admission_full -> true
  | Inflight_capacity_exceeded -> true
  | Capability_profile_mismatch _ -> true
  | _ -> false
```

단, `Keeper_error_classify.error_class` 가 현재 typed sum 이 아니라면, 본 RFC 는 `keeper_health_probe.ml` 의 문자열 분기를 *단계적으로* 교체: 먼저 `keeper_error_classify.ml` 에 typed `tier_admission_reason` closed-sum 을 도입하고, `keeper_health_probe.ml` 은 그것을 consume 한다.

### 3.4 `required_tool_unsupported` integration

RFC-0157 이 도입하는 `Required_tool_unsupported` variant 는 `Tier_admission_full` 과 별개의 분기가 되어야 한다. `is_tier_admission_error` 에 포함시키지 않는다 — 의미적으로 다륾 (capability mismatch vs admission capacity).

```ocaml
let classify_from_typed_error = function
  | Keeper_error_classify.Tier_admission_full -> Tier_admission_full
  | Keeper_error_classify.Inflight_capacity_exceeded -> Tier_admission_full
  | Keeper_error_classify.Required_tool_unsupported _ ->
      Required_tool_unsupported  (* NEW arm, distinct from Tier_admission *)
  | Keeper_error_classify.Capability_profile_mismatch _ ->
      Capability_profile_mismatch
  | ... -> (* existing arms *)
```

## §4 Migration

| Phase | 작업 | 측정 |
|---|---|---|
| **A** | `Cascade_name` 모듈 신설. `cascade_catalog_runtime_resolve.ml` 에 `Cascade_name.of_string` 적용 — short form caller 는 동시에 canonical path 로 교체. `dune build @all` 통과. | (a) 기존 short form caller 0개 확인 (`rg '"strict_tool_candidates"' lib/` 가 0 match); (b) unit test: `of_string "tier-group.X"` -> Ok, `of_string "X"` -> Error |
| **B** | `keeper_health_probe.ml` 의 `Tier_admission_full` 분기를 typed variant 기반으로 교체. `contains` 기반 문자열 매칭 제거. | (a) `rg 'contains.*strict_tool_candidates' lib/keeper/` 0 match; (b) 새 tier admission 관련 typed error 추가 시 컴파일러가 `keeper_health_probe.ml` 의 `match` 누락 감지 |
| **C** | `Cascade_name.t` 를 다른 `cascade_name` consumer 로 확산 — `keeper_turn_driver.ml`, `cascade_attempt_fsm.ml`, `cascade_capability_profile.ml` 등. | 각 consumer 파일에서 `string` 타입의 `cascade_name` 인자가 `Cascade_name.t` 로 교첵. 컴파일 오류 = 미변경 사이트 식별 |

Phase A 가 first commit. Phase C 완료 후 본 RFC `Implemented` 로 이행.

## §5 Workaround rejection self-check

`software-development.md` §워크어라운드 거부 기준 체크리스트 7항목 대조:

| # | 시그니처 | 본 RFC 해당? | 근거 |
|---|---|---|---|
| 1 | "makes X visible" / "instrument Y" only (fix 없음) | **No** | fix = auto-normalize 제거 + typed sum 도입. 카운터 없음 |
| 2 | string/substring/prefix 분류기 추가 | **No** | *제거* 대상. `contains` 분기를 typed variant 로 교체 |
| 3 | "PR #N only fixed K of M sites" | **No** | 단일 boundary (`Cascade_name.of_string`) + 단일 consumer 교체 (`keeper_health_probe.ml`) |
| 4 | catch-all `_ ->` 추가 | **No** | `Cascade_name.of_string` 의 `result` 타입이 모든 오류를 명시. `_ ->` 없음 |
| 5 | cap/cooldown/dedup/repair (대체 RFC 없음) | **No** | RFC-0058 (route canonical path) 와 명시적 연결. 본 RFC 는 0058 의 구멍을 메움 |
| 6 | test backdoor 노출 | **No** | `of_string_exn` 은 개발 convenience 일 뿐 test 전용 아님. production caller 는 `of_string` 사용 |
| 7 | 같은 typo/off-by-one 을 N 사이트에 N 번 fix (codemod 미수행) | **No** | 단일 parse 함수로 일괄 교체 |

7/7 통과.

## §6 Risks

### 6.1 External caller breakage

MASC 외부의 consumer (dashboard, CLI, 다른 서비스) 가 short form 을 본문에 하드코딩했을 수 있다. Phase A 에서 `rg '"[^"]*tool_candidates[^"]*"' lib/ test/ dashboard/src/` 로 전수 확인.

완화: 외부 caller 가 있다면 Phase A PR 에 함께 교체. 외부 caller 가 많으면 Phase A 를 "reject + 명시적 오류 메시지" 로만 유지하고, Phase B 에서 외부 교체 완료.

### 6.2 `private string` 의 ergonomic cost

`Cascade_name.t` 를 `Printf.sprintf` 에 넣거나 `Yojson.Safe.t` 로 직렬화할 때 `to_string` 호출이 번거로울 수 있다.

완화: `Format` 의 `"%a"` 프린터 제공 (`val pp`). `Yojson` 직렬화는 `to_string` 한 번 — 기존 문자열 처리와 동일한 비용.

### 6.3 `Keeper_error_classify` 가 아직 untyped

§3.3 의 설계는 `Keeper_error_classify.error_class` 가 이미 typed sum 이라고 가정한다. 실제로는 문자열 기반일 수 있다.

완화: Phase B 시작 전 `keeper_error_classify.ml` 의 현재 타입을 확인. untyped 라면 본 RFC Phase B 를 "`keeper_error_classify` 에 typed sum 신설" 로 확장하거나, 별도 RFC 로 분리. 본 RFC scope 는 Phase A (route canonicalization) 로 축소 가능.

## §7 Acceptance criteria

Phase C 완료 후:

1. `rg 'List.find_opt.*tier-group\|List.find_opt.*tier\.' lib/cascade/` 0 match — auto-normalize 코드 완전 제거
2. `rg 'contains.*strict_tool_candidates' lib/keeper/` 0 match — 문자열 분류기 제거
3. `Cascade_name.of_string "strict_tool_candidates"` -> `Error `Invalid_prefix` — unit test 로 고정
4. `dune build @all` 및 `dune build @runtest` 통과
5. (선택) `Cascade_name.t` 를 사용하는 consumer 파일 수 / 전체 `cascade_name` consumer 파일 수 >= 0.5

## §8 Relation to RFC-0157

| | RFC-0157 | RFC-0163 (본 RFC) |
|---|---|---|
| **문제** | required-tool 을 만족하지 못하는 candidate 를 사전에 필터 | route canonical path 를 우회하는 short form + 문자열 분류기 |
| **계층** | turn 진입 직전 (capability gate) | route resolution 시점 (catalog runtime) |
| **typed 도입** | `Provider_capability.t`, `Cascade_candidate_skip_reason.t` | `Cascade_name.t`, `Keeper_error_classify` typed sum |
| **관계** | sister — 같은 "capability boundary 를 typed 로 lift" 방향 | sister — 같은 "capability boundary 를 typed 로 lift" 방향 |

두 RFC 는 독립적으로 merge 가능. 순서: RFC-0163 Phase A (route canonicalization) 먼저 -> RFC-0157 Phase A (pre-dispatch gate wiring) 가 `Cascade_name.t` 를 그대로 사용.
