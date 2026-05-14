---
rfc: RFC-0038 Phase 2
title: Keeper Identity Canonical Form (alias canonicalization)
author: jeong-sik
created: 2026-05-09
status: Draft (sketch)
supersedes: -
related:
  - RFC-0038 Phase 1 (opaque identifier types — Provider_id, Cascade_name)
  - RFC-0020 (keeper event queue layer separation — identity transport)
  - RFC-0041 (cascade routing group/item hierarchy — identity 참조)
  - PR #14038 (fix: compare task owners by stable identity — reference fix)
---

# RFC-0038 Phase 2: Keeper Identity Canonical Form (alias canonicalization)

> **Status**: Draft sketch (RFC-0038 Phase 1 확장). Caller-context inventory at `.tmp/rfc-0038-p2-caller-context.md` pending sub-agent.

## §0 Summary

RFC-0038 Phase 1이 opaque identifier types (`Provider_id.t = private string`, `Cascade_name.t = private string`)를 도입했으나 keeper identity는 여전히 raw string으로 비교된다. 이로 인해:
- `nick0cave` vs `keeper-nick0cave-agent` vs generated nickname이 **같은 keeper를 참조하나 string equality로 reject**
- task ownership `release/done/cancel` 경로에서 false rejection
- codex-connector P1 review: alias 매칭 통과 후 `transition_task_r`이 canonical assignee의 `current_task` 클리어를 누락 → backlog/agent metadata drift

본 Phase 2는 **keeper identity canonical form**을 type level로 표현하여 모든 alias가 single canonical form으로 normalize되어야 함을 컴파일러 강제.

## §1 Problem (caller-context inventory)

### §1.1 Core ownership comparison — raw `String.equal` everywhere

**sub-agent 발견: `same_task_actor`는 현재 코드베이스에 존재하지 않음.**

RFC 초안에서 인용한 `coord_task.ml:109`의 `same_task_actor`는 과거 commit(`3904e285b8`)의 코드로, 현재 HEAD에서는 리팩토링되어 `Coord_task_lifecycle.decide` 낙에 `same_agent` closure로 이동:

```ocaml
(* lib/coord/coord_task_lifecycle.ml:48 *)
let same_agent assignee = String.equal assignee agent_name in
```

이 `same_agent`가 FSM 전이 10개 이상의 지점에서 사용됨(lifecycle.ml:54,62,67,75,79,92,103,116,152,174). 모든 지점이 **raw `String.equal`**.

**Task FSM의 identity 비교 전수 (sub-agent Topic C.1 결과)**:

| 파일 | 라인 | 패턴 | 역할 |
|------|------|------|------|
| `coord_task_lifecycle.ml` | 48 | `String.equal assignee agent_name` | **FSM ownership core** |
| `coord_task.ml` | 129 | `a <> agent_name` | assignee mismatch hint |
| `coord_task.ml` | 149 | `a = agent_name` | remediation ownership |
| `coord_task.ml` | 841 | `assignee = agent_name` | cancel_task_r guard |
| `coord_task_schedule.ml` | 293, 423 | `String.equal assignee agent_name` | scheduling match |
| `tool_task.ml` | 235, 379 | `String.equal assignee agent_name` | tool-layer check |

→ **0개 typed identity comparison**. `Keeper_identity.canonical_keeper_name_from_agent_name` 등 canonicalization helper가 존재하나 task FSM에서는 전혀 사용되지 않음.

**PR #14038 / codex-connector P1 review에서 지적한 버그**:
> "`transition_task_r`이 caller string 그대로 agent state를 갱신하면, canonical assignee의 `current_task` 클리어 + status update가 발생하지 않아"

실제 코드 확인: `transition_task_r` line 48에서 `resolve_agent_name_strict`로 caller를 canonicalize한 뒤 `update_local_agent_state`를 호출. 이는 **caller 측** state는 올바르게 갱신하나, task가 **다른 alias**로 claim된 경우 assignee 측 state 파일은 건드리지 않음.

### §1.2 이미 존재하는 workaround들 — diagnosis 확인

sub-agent가 3개의 dual-name matching workaround를 발견:

```ocaml
(* lib/tool_task.ml:145 *)
let matches_you assignee =
  String.equal assignee ctx.agent_name || String.equal assignee actual_name

(* lib/tool_coord.ml:424 *)
let matches_you assignee =
  String.equal assignee ctx.agent_name || String.equal assignee actual_name

(* lib/keeper/keeper_current_task_reconcile.ml:41 *)
let matches assignee = List.mem assignee names in
(* names = [agent_name; resolved_name] *)
```

→ 코드베이스가 이미 alias 문제를 **현장에서 workaround**로 해결하고 있다. 이는 RFC의 diagnosis가 정확함을 증명.

### §1.3 Alias 생성 경로

**메모리 `feedback_blocker_class_stamp_gap_completion_contract.md` 연관**: "blocker class stamp gap — text는 있는데 enum null"
→ text identity가 존재하나 typed identity가 없는 같은 근본 문제 (type이 없으면 normalize 불가).

**Alias 생성 경로 (sub-agent Topic C.2 결과)**:

| 경로 | 파일 | 형태 | 예시 |
|------|------|------|------|
| toml config | `config/keepers/*.toml` | canonical | `persona_name = "sangsu"` |
| transport | `keeper_heartbeat_loop.ml` | derived | `keeper-sangsu-agent` |
| generated | `keeper_nickname_generator.ml` | volatile | `swift-fox-a3b2` |
| parsed | `keeper_identity.ml:50-88` | 4-way prefix/suffix | `keeper_<name>_agent` 등 |

`keeper_identity.ml:50-88`의 파서가 4가지 조합 처리:
```ocaml
let keeper_name_from_agent_name agent_name =
  match parse_keeper_agent_name ~prefix:"keeper-" ~suffix:"-agent" agent_name with
  | Some keeper_name -> Some keeper_name
  | None -> match parse_keeper_agent_name ~prefix:"keeper_" ~suffix:"_agent" agent_name with
  ...
```

→ 모든 경로가 같은 canonical name(`sangsu`)에서 derive되나 현재는 **독립적 string으로 처리**됨. `keeper_meta`는 `name`과 `agent_name`을 둘 다 보유하나 비교 시점에서 어떤 필드를 쓸지 caller가 결정.

### §1.3 RFC-0038 Phase 1과의 격차

Phase 1은 `Provider_id.t = private string`, `Cascade_name.t = private string`를 도입.
Phase 2는 keeper identity를 동일 패턴으로 확장: `Keeper_identity.t = private string` with **canonical form guarantee**.

## §2 Goals / Non-goals

### Goals
- keeper identity alias 생성 경로를 canonical form으로 normalize
- `Keeper_identity.t` opaque type 도입 (`Provider_id`, `Cascade_name` 패턴 확장)
- `same_task_actor`를 type level 강제: alias 매칭이 아니라 canonical comparison
- `transition_task_r`에서 canonical assignee로 state 갱신

### Non-goals
- nickname generator 전면 제거 (derivation mechanism 유지)
- transport alias format 변경 (형식 그대로)
- 전체 toml config 재설계

## §3 Design

### §3.1 `Keeper_identity` opaque type with canonical form

```ocaml
module Keeper_identity : sig
  type t = private string  (* RFC-0038 Phase 1 패턴 확장 *)
  val canonicalize : string -> t option  (* alias → canonical form *)
  val to_string : t -> string  (* canonical form 출력 *)

  val alias_of : t -> Alias.t option  (* optional alias, volatile *)
end

module Alias : sig
  type t =
    | Transport of { prefix : string; suffix : string }  (* keeper-<name>-agent *)
    | Generated of { nickname : string; seed : int }    (* volatile *)
    | Custom of string
end
```

→ alias는 **optional derived property**로 canonical form에서 분리. task ownership 비교는 항상 canonical form.

### §3.2 Canonical form creation rules

```ocaml
type canonical_error =
  | Invalid_name of string
  | Reserved_keyword of string
  | Too_long of { max : int; actual : int }
```

Rule (sub-agent Topic C.2 결과로 확정):
<!-- TODO: alias 생성 경로 분석 결과로 rule 확정 -->
- toml `name` field가 source of truth
- `keeper-<name>-agent` → `<name>` 추출
- generated nickname → `canonicalize(nickname)` → mapping table

### §3.3 Task ownership FSM 갱신

```ocaml
let transition_task_r ~identity ~task_state =
  let canonical = Keeper_identity.canonicalize identity in
  (* canonical form으로 agent state 갱신 *)
  ...
```

→ PR #14038의 `transition_task_r` normalize 계획이 Phase 2 §3.3으로 흡수.

## §4 Implementation Plan

### PR-A: Type infrastructure
- `lib/types/keeper_identity.ml{i}` — opaque type + canonicalize
- RFC-0038 Phase 1과 동일 디렉토리 convention

### PR-B: Alias generation path migration
- 각 alias 생성 사이트에서 `Keeper_identity.t` 생성 (sub-agent Topic C.2 결과 기반)
- backward-compat: 기존 string 비교는 deprecation 경고

### PR-C: Task FSM migration
- `coord_task.ml` `same_task_actor` → `Keeper_identity.equal`
- `transition_task_r` → canonical form으로 state 갱신
- PR #14038의 test coverage 재사용

### PR-D: 전체 alias 호출 사이트 마이그레이션
- sub-agent Topic C.1 결과 기반

## §5 Alternatives

| 접근법 | Canonical Form | Stability | Uniqueness | masc-mcp 적합도 |
|---|---|---|---|---|
| ActivityPub `id` | HTTPS URI | ✅ Stable | ✅ Global (URI) | **높음** — `keeper_name`을 canonical ID로, `agent_name`을 alias로 |
| OIDC `iss`+`sub` | issuer-scoped string | ✅ Immutable | ✅ Global (iss+sub) | **높음** — `keeper_name`을 immutable `sub`로 취급 |
| WebFinger `acct` | `acct:user@domain` | ✅ Stable | ✅ Global (domain-scoped) | **중간** — URI-like 식별자 도입 시 참고 |
| DID | `did:method:specific` | ✅ Self-sovereign | ✅ Global | **낮음** — over-engineering, single-domain 시스템 |
| RFC 5321 Mailbox | `local@domain` | ⚠️ Case-sensitive | ⚠️ Local-part ambiguous | **낮음** — delivery vs identity 목적 불일치 |
| DNS Punycode/IDNA | Punycode ASCII | ✅ Stable | ✅ Global | **낮음** — internationalization 문제 없음, overkill |

### 권장 방향

**채택: ActivityPub + OIDC Hybrid Model**
- `keeper_name`을 canonical identifier로 명시. 속성: immutable, never reassigned, locally unique within masc instance.
- `agent_name`을 display/handle로 분리. `preferredUsername`처럼 mutable, non-unique. UI 표시용.
- `persona_name` = `keeper_name` (1:1). `credential_stem` = `keeper_name` (1:1). 이 관계를 타입으로 보증.
- `canonical_keeper_name`의 4가지 prefix/suffix 조합 처리를 "legacy alias resolution"으로 재명명. 새 코드는 canonical `keeper_name`만 사용.
- 단점: 기존 `agent_name`과 `keeper_name`이 다른 keeper들의 마이그레이션 필요. `keeper_name_from_agent_name`의 4-way match는 deprecation path 필요.

## §6 Open Questions

1. nickname → canonical form mapping table의 persistence (SQLite? pgvector? memory-only?)
2. generated nickname이 셔플되면 이전 identity mapping은 invalid? or versioned?
3. `Keeper_identity.t`가 RFC-0038의 `Provider_id`, `Cascade_name`와 동일한 module (opaque) convention을 따르는가, or separate?
4. codex-connector P1 review에서 지적한 `transition_task_r` backward-compat: 기존 task record의 `owner` 필드는 그대로 두고 비교 시점만 canonicalize하는 방식 vs migration
5. sub-agent Topic C.2 결과로 alias 생성 사이트 추가

## §7 References

### 외부

- W3C ActivityPub Specification — actor `id` as canonical identifier (https://www.w3.org/TR/activitypub/)
- ActivityPub and WebFinger CG Final Report 2024 — "SHOULD NOT treat usernames as stable identifiers" (https://www.w3.org/community/reports/socialcg/CG-FINAL-apwf-20240608/)
- OpenID Connect Core 1.0 — `sub` claim immutability (https://openid.net/specs/openid-connect-core-1_0.html)
- WebFinger RFC 7033 + `acct` URI RFC 7565 (https://www.rfc-editor.org/rfc/rfc7033)
- RFC 5321 Section 4.1.2 — local-part case sensitivity (https://datatracker.ietf.org/doc/html/rfc5321)
- DID W3C Specification — over-engineering verification (https://www.w3.org/TR/did-resolution/)

### 사내

- RFC-0038 Phase 1 (opaque identifier types — `Provider_id.t`, `Cascade_name.t`)
- PR #14038 — reference fix + codex-connector P1 review
- `instructions/software-development.md` §2 Unknown → Permissive Default anti-pattern
- (sub-agent Topic C.1) `same_task_actor` caller 전수 + `transition_task_r` 연결 — `.tmp/rfc-0038-p2-caller-context.md`
- (sub-agent Topic C.2) alias 생성 사이트 분석 — `.tmp/rfc-0038-p2-caller-context.md`
- (사내) memory `feedback_blocker_class_stamp_gap_completion_contract.md` (type 없는 identity 관련)

---

🤖 Generated by /loop session — sub-agent results pending integration
