---
rfc: "0111"
title: "Goal mint atomicity — auto-goal uniqueness invariant at write boundary"
status: Implemented
created: 2026-05-17
updated: 2026-05-22
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088", "0110"]
implementation_prs: [15927]
---

# RFC-0111: Goal mint atomicity — auto-goal uniqueness invariant at write boundary

## §1 Problem (caller-context)

PR #15893 `fix(goal): keeper_goal_repair dedupe + janitor auto-stagnate threshold (P0)` 의 PR body:

> Two surgical fixes for auto-goal accretion observed live 2026-05-17 (Goal Store 70 goals, 3 identical verifier-keeper goals across 10 days).

`lib/keeper/keeper_goal_repair.mli:19-24` 가 그 근거를 코드 안에 그대로 둠:

```
type repair_source = [ `Created | `Reused ]
(** Records whether {!run} {b created} a new goal or {b reused} an
    existing auto-goal with the same derived title.  Reuse path closes
    the auto-goal accretion observed live 2026-05-17 (Goal Store had 3
    identical verifier-keeper goals across 10 days because each repair
    turn minted a fresh id). *)
```

### 워크어라운드 3 시그니처 동시 발화

PR #15893 가 한 PR 안에 AGENT-LLM-A.md `software-development.md` §"워크어라운드 거부 기준" 의 **3 시그니처를 동시** 도입:

1. **String/Substring 분류기 보강** (§"String classifier"):
   - `goal_title_of_purpose` 가 모든 auto-goal 에 `" (auto)"` 접미사 부착
   - A suffix-based lifecycle policy is unsafe because titles are not typed
     ownership or lifecycle state.
   - 결과: title 이 ownership / lifecycle 분류기 역할. `Set<string>` 가 *closed sum* 대신 사용됨.

2. **Cap / Cooldown** (§"Cap / Cooldown"):
   - `goal_title_of_purpose`: 115-char truncation cap (130-char total 한계)
   - `sweep_config.auto_stagnant_days` default 7 day cap on auto-goal 수명
   - 둘 다 *왜 unbounded* 인지 닫지 않고 cap 만 부착.

3. **Repair / Sanitize** (§"Repair / Sanitize"):
   - `find_existing_auto_goal` 가 mint 시점에 *title-equality scan* 으로 read-side dedupe
   - `[`Created | `Reused]` variant 가 repair 결과에 분류 부착
   - mint 자체가 unique 함을 보장하지 않음.

### Root cause

`Goal_store` 의 mint 인터페이스가 *uniqueness 를 invariant 로 갖지 않는다*. PR #15893 직전 mint API:

```ocaml
(* keeper_goal_repair.ml 원본 *)
let goal_id = Workspace.generate_goal_id () in
Goal_store.upsert ~goal_id ~title ~purpose ...
```

같은 `(keeper_name, title)` 에 대해 mint 가 fresh id 를 생성. 10일간 verifier-keeper repair 가 10번 돌면 10개 goal. PR #15893 의 dedupe 는 *read-side scan + 같은 title 발견 시 reuse* 로 막음 — 하지만 race condition (두 repair turn 이 동시에 scan + mint) 은 여전히 가능.

`Workspace.generate_goal_id` 는 (현재) collision-resistant nonce — 그런데 *uniqueness key* 는 nonce 가 아니라 `(keeper_name, purpose-derived-title)` 이어야 함. 자료 model 과 invariant 불일치.

### Why this needs an RFC

1. **누적 메커니즘**: 다른 mint caller (예: 사용자 generated goal, MASC API `masc_goal_upsert`) 도 같은 invariant 문제. PR #15893 는 *Keeper_goal_repair* 한 caller 만 수정 — 다른 caller 가 같은 race 재발 시 또 다른 PR 필요. AGENT-LLM-A.md §"N-of-M 패치".
2. **String classifier 의존**: " (auto)" 접미사로 *어떤 goal 이 auto* 인지 결정. 사용자가 manually 같은 title 의 goal 을 만들면 janitor 가 잘못 sweep. closed sum (`Goal_source : Auto | User | System`) 으로 좁힐 수 있음.
3. **Cap 의 의미 분리 부재**: `auto_stagnant_days = 7` 은 *idle stagnant* 와 *auto-goal lifecycle* 두 의미를 하나의 cap 으로 합침.

근본 원인: **`Goal_store` 가 mint-side uniqueness invariant 와 source-typed lifecycle 을 type 으로 표현 안 한다.**

## §2 Approach

3 layer:

**Layer A — Goal source typed at mint**

`Goal_source.t` closed sum:

```ocaml
module Goal_source : sig
  type t =
    | Auto_keeper_repair of { keeper_name : string }
    | Auto_system of { rationale : string }
    | User of { author : string }
    | Cli of { invocation : string }
  val to_string : t -> string
  val of_string : string -> (t, [ `Unknown_source of string ]) Result.t
end
```

기존 `" (auto)"` 접미사 의존 제거. `Goal.t` record 에 `source : Goal_source.t` 필드 추가. Janitor 는 `match source with Auto_keeper_repair _ -> ...` 로 typed dispatch.

**Layer B — Uniqueness key at mint**

`Goal_store.mint` API 가 `~uniqueness_key:(keeper_name * goal_purpose_hash) option` 받음. `None` = 항상 새 mint (e.g. User goal). `Some k` = race-free dedupe (Eio.Mutex 또는 Atomic.compare_and_set 기반).

```ocaml
val mint :
  ~source:Goal_source.t ->
  ~uniqueness_key:( string * string ) option ->
  ~title:string ->
  ~purpose:string ->
  ... ->
  (Goal.t, [ `Reused of Goal.t | `Conflict of Goal.t list ]) Result.t
```

`Result.Error (`Reused existing)` 가 fresh mint 실패 시 호출자에게 명시. PR #15893 의 `Created | Reused` 가 단일 결정점에서 발생.

**Layer C — Repair function sunset**

`keeper_goal_repair.find_existing_auto_goal` 는 *legacy adapter* 로 좁힘. 본 RFC merge 후 새 mint caller 는 `Goal_store.mint ~uniqueness_key:Some _` 만 사용. `auto_stagnant_days` cap 은 *idle 의미만* 의 cap 으로 좁히고 *auto-goal lifecycle* 는 별도 정책 (e.g. Goal_source 기반 retention) 으로 분리.

## §3 Phasing

| Phase | Deliverable | Acceptance |
|---|---|---|
| P1 (this PR) | RFC body | Draft → main |
| P2 | `Goal_source.t` closed sum + `Goal.t.source` field migration | 기존 goal 은 default `Auto_system { rationale = "legacy" }`. dune build PASS. |
| P3 | `Goal_store.mint ~uniqueness_key` API + Eio.Mutex-based race-free dedupe | PBT: 두 concurrent mint with same key → exactly 1 mint + 1 `Reused`. PR #15893 의 dedupe scan 호출은 `mint` 로 delegate. |
| P4 | Remove suffix-based lifecycle policy instead of teaching it source matching | Goal lifecycle changes must be explicit operator/judge actions. |
| P5 | Remove lifecycle env policy knobs instead of splitting sweep thresholds | No background sweep policy knobs remain. |
| P6 | `keeper_goal_repair.find_existing_auto_goal` + `repair_source = Created \| Reused` 제거 | `dune build` PASS. LoC −80 추정. |

P3 가 핵심 — concurrent mint 의 race window 가 진짜 닫힘. P5 는 cap 의미 분리다.

## §4 Open questions

1. **Q1**: Legacy goal (이미 disk 에 있는 goal 중 `source` 필드 없는 것) 처리? P2 에서 (a) migration script 가 title `" (auto)"` 접미사 보고 retroactively `source` 추론 vs (b) 모두 `Auto_system { rationale = "legacy" }` default. **잠정**: (b). 후속 정확성 필요 시 별도 migration RFC.

2. **Q2**: `uniqueness_key` 의 두 번째 element 가 `goal_purpose_hash` 인지 `goal_title_hash` 인지? title 은 truncated (115-char), purpose 는 full. **잠정**: `purpose_hash` (truncation 이 mint 의미에 영향 없도록).

3. **Q3**: `Reused` 반환 시 호출자가 stale goal 의 metadata 를 *갱신* 할지? 예: 새 mint 가 같은 purpose 지만 다른 ENV 정보를 carry. **잠정**: `mint` 는 reuse-as-is. 갱신은 `Goal_store.update_metadata` 별도 API.

## §5 Non-goals

- **외부 protocol** (예: MCP `masc_goal_upsert` 의 wire schema 변경) — 본 RFC 는 *내부 mint API* 만. wire schema 는 별도.
- **Goal-Keeper relation lifecycle** (예: keeper down 시 goal 처리) — RFC-OAS 또는 별도.
- **Janitor 의 *idle* sweep 정책 자체** — Cap 의 의미 분리만, 정책 변경 아님.

## §6 Risk & rollback

- **Risk 1**: P2 `Goal.t.source` 필드 추가가 disk format 변경. 옛 binary 가 새 format goal 읽기 가능해야 함. → P2 의 yojson decoder 가 missing `source` 필드 = default `Auto_system` 로 fallback (RFC-OAS-008 패턴).
- **Risk 2**: P3 의 Eio.Mutex 가 mint-rate hot path 에 lock contention. → mint 는 (현재 측정) 분당 < 10 calls — overhead 무시 가능. RFC-0107 의 per-path Eio.Mutex 패턴 차용.
- **Risk 3**: Legacy goal 의 `(auto)` 접미사 가 janitor sweep 의미 carry. P4 에서 sweep 결정이 `source` 기반으로 바뀌면 옛 goal sweep 제외 가능. → P4 migration step: 옛 goal scan, title 에 `(auto)` 있고 `source = Auto_system "legacy"` 면 `source = Auto_keeper_repair { keeper_name = <derive> }` 로 in-place 갱신.

Rollback: 각 Phase 별 단일 PR. P3 revert 가능 (mint API legacy path 한 PR 안에서 보존). P5 cap 분리 도 두 env knob 모두 default 값 유지하면 behavior unchanged.

## §7 Acceptance

- [ ] P1: RFC body merge.
- [ ] P2: `Goal_source.t` 정의 + legacy default decoder, disk read regression test PASS.
- [ ] P3: `Goal_store.mint ~uniqueness_key` race-free PBT PASS, `keeper_goal_repair.find_existing_auto_goal` 호출 0건.
- [ ] P4: Janitor 가 typed `source` 로 dispatch. User goal w/ "(auto)" title 이 sweep 제외 확인.
- [ ] P5: 2 env knob 도입, default 값 시 behavior unchanged.
- [ ] P6: legacy `find_existing_auto_goal` + `Created | Reused` variant 제거.

## §8 Number allocation note

Allocated as RFC-0111. Ledger advanced 0109 → 0112 (skip 0109 already taken by inflight #15902 RFC-0109 CDAL × GOAL Integration Contract, skip 0110 already taken by inflight #15924 RFC-0110 tool-pair atomicity — same iter-1/2 author). Per README policy "skipped numbers reserved against reuse — ledger is monotonic."

Note: main 에 RFC-0108 *2건 동시 점유* 사고 발생 — `RFC-0108-atomic-jsonl-append.md` (#15901 merged 11:13Z) + `RFC-0108-pr-worktree-operation-safety-gates.md` (#15921 merged 11:18Z, 5분 차이). RFC-0078 ledger + 이 RFC 의 후속 인 RFC-0108 PR Safety Gates §3.4 Gate-4 가 정확히 막아야 했던 시나리오 — 사후 분석은 follow-up issue.
