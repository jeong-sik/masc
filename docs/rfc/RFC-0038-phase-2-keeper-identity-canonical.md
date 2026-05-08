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

### §1.1 `coord_task.ml` `same_task_actor` 함수

**현재 main 코드** (`origin/main` `3904e285b8`, `lib/coord/coord_task.ml` line 109):

```ocaml
let same_task_actor ~caller ~assignee =
  (* 14038 PR이 제안: canonical form 비교 + alias-equivalent 확인 *)
  String.equal caller assignee
  (* → nick0cave != keeper-nick0cave-agent reject *)
```

**PR #14038 reference fix** (head commit):
- `same_task_actor`에 alias-equivalent 매칭 추가
- codex-connector P1 review (05-07 05:34Z):
  > "`same_task_actor` alias 매칭으로 transition이 통과하는데 후속 `transition_task_r`이 caller string 그대로 agent state를 갱신하면, canonical assignee의 `current_task` 클리어 + status update가 발생하지 않아"

**caller-context (sub-agent Topic C 결과 통합 영역)**:
<!-- TODO: Topic C.1 — same_task_actor caller 전수 + transition_task_r 연결 -->
<!-- TODO: Topic C.2 — alias 생성 사이트 (nick0cave, keeper-nick0cave-agent, generated nickname) -->

### §1.2 identity 생성 경로

**메모리 `feedback_blocker_class_stamp_gap_completion_contract.md` 연관**: "blocker class stamp gap — text는 있는데 enum null"
→ text identity가 존재하나 typed identity가 없는 같은 근본 문제 (type이 없으면 normalize 불가).

**생성 경로 (sub-agent Topic C.2 결과로 확정)**:
<!-- TODO: keeper alias 생성 사이트 -->
1. `config/keepers/*.toml` — `name = "nick0cave"` (canonical form)
2. `keeper_heartbeat_loop.ml` — transport alias: `keeper-<name>-agent` (derived)
3. `keeper_nickname_generator.ml` — generated nickname (volatile)

→ 모두 같은 canonical name(`nick0cave`)에서 derive되나 현재는 독립적 string으로 처리됨.

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

<!-- TODO: research/2026-05-09-identity-canonicalization-patterns.md 의 비교 표 통합 -->

- DNS canonicalization (Punycode/IDNA) — 긴 canonical name 처리
- ActivityPub `id` vs `preferredUsername` — canonical URL vs display name
- OIDC `sub` claim (immutable) vs `preferred_username` (변경 가능)
- DID (Decentralized Identifier) — 너무 과함
- WebFinger `acct:` URI — email-like scheme

→ **권장**: ActivityPub `id` + `preferredUsername` 패턴 (canonical form + display alias)

## §6 Open Questions

1. nickname → canonical form mapping table의 persistence (SQLite? pgvector? memory-only?)
2. generated nickname이 셔플되면 이전 identity mapping은 invalid? or versioned?
3. `Keeper_identity.t`가 RFC-0038의 `Provider_id`, `Cascade_name`와 동일한 module (opaque) convention을 따르는가, or separate?
4. codex-connector P1 review에서 지적한 `transition_task_r` backward-compat: 기존 task record의 `owner` 필드는 그대로 두고 비교 시점만 canonicalize하는 방식 vs migration
5. sub-agent Topic C.2 결과로 alias 생성 사이트 추가

## §7 References

<!-- TODO: ~/me/knowledge/research/2026-05-09-identity-canonicalization-patterns.md 인용 -->

- (sub-agent Topic C) ActivityPub actor identity (id vs preferredUsername)
- (sub-agent Topic C) OIDC sub claim + preferred_username
- (sub-agent Topic C) DID W3C (overkill 검증)
- (sub-agent Topic C) Git commit identity canonicalization
- (사내) RFC-0038 Phase 1 (opaque identifier types)
- (사내) PR #14038 — reference fix + codex-connector P1 review
- (사내) memory `feedback_blocker_class_stamp_gap_completion_contract.md` (type 없는 identity 관련)

---

🤖 Generated by /loop session — sub-agent results pending integration
