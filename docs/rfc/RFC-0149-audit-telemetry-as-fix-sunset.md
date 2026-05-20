# RFC-0149 — Audit-Driven Telemetry-as-Fix Sunset (memory_recall · compact_negative_savings · cascade_resolve_live_warn)

- **Status**: Active
- **Created**: 2026-05-20
- **Owner**: keeper observability + memory + cascade
- **Predecessors**: masc-mcp #16771, #16778, #16787 (all MERGED to main 2026-05-19)
- **Evidence base**: `~/me/memory/masc-mcp-code-flowchart-audit-2026-05-20.html` §3 MEMORY, §4 COMPACT, §6 CASCADE
- **Related**: RFC-0144 (workaround sunset taxonomy), RFC-0145 (permissive silent fallback elimination)

## 1. Motivation

A 2026-05-20 six-subsystem audit (Turn / Life / Memory / Compact / Tool / Cascade) identified 3 silent-failure pathways that an immediate follow-up sprint *fixed* by adding Prometheus counters / WARN-once logs while explicitly preserving the silent behavior. All three PR bodies state "Behavior is unchanged".

This pattern is the exact match for `~/me/instructions/software-development.md` §워크어라운드 거부 기준 §1 (텔레메트리-as-fix):

> PR이 silent failure를 *visible*로 만들지만 *fix*하지 않음. 신호: "make data loss visible to operators", "count drops", "instrument X failure". 본질: counter는 *alarm*이지 *fix*가 아님.

The PR머지 거부 체크리스트 §1 ("makes X visible / instrument Y 만 수행, fix 없음 → 머지 거부, RFC로 흡수") applies. Override 조건 (PR body 의 `WORKAROUND:` 라벨 + 대체 RFC 명시 + sunset target) 은 셋 다 충족하지 않았음 — 본 RFC 가 그 누락을 사후 보강하고 typed boundary 대체 설계로 흡수한다.

The audit itself flagged this anti-pattern. The follow-up sprint then reproduced it. That self-recurrence is itself the most important finding of the sprint and is recorded in `memory/feedback_telemetry_as_fix_self_recurrence.md`.

## 2. Scope

In scope (3 deprecated-path workarounds, all already merged):

| PR | Site | Workaround signature |
|---|---|---|
| #16771 (`5ab5b97f1e`) | `lib/keeper/keeper_memory_recall.ml:73-75` `read_file_tail_lines` | `try ... -> []` + counter + WARN. Read failure still returns `[]`. |
| #16778 (`cac8880268`) | `lib/keeper/keeper_compact_policy.ml:312-326` `saved_tokens` / `saved_messages` | `max 0 (pre - post)` + counter. Negative-delta still silently floored. |
| #16787 (`3bf5f555df`) | `lib/keeper/keeper_cascade_profile.ml:518-538` `resolve_live_with_catalog` | Silent fallback to `Keeper_turn` + counter + WARN-once. Typo / stale ref still routes to default. |

Out of scope (separate RFC candidates from the same audit):

- B1 LIFE: Dead phase entry-action ordering race (`keeper_state_machine.ml:773-778`).
- B2 MEMORY: RFC-0107 `Jsonl_atomic` adoption for memory bank compaction.
- B3 CASCADE: cascade.toml unknown field strict validation.
- B4 CASCADE: `cascade_inference.ml:59-82` inference param fail-OPEN.
- B6 TURN: `keeper_turn_cascade_budget_routing.ml:11,17` string prefix dispatch → tagged variant.

## 3. Root-fix (typed boundary) per workaround

### 3.1 `read_file_tail_lines` — `Result.t` + caller-side handling (replaces #16771)

Current signature swallows IO failure into `[]` and emits a counter:

```ocaml
val read_file_tail_lines :
  string -> max_bytes:int -> max_lines:int -> string list
```

Replacement signature pushes the failure to the caller boundary:

```ocaml
val read_file_tail_lines :
  string -> max_bytes:int -> max_lines:int
  -> (string list, Keeper_memory_recall_exn_class.t) result
```

Caller sites (Empty `[]` "no memory" vs. `Error _` "fs/permission fault"):

- `read_keeper_memory_summary` (`keeper_memory_recall.ml:77-148`) — branch on `Ok` (compute summary) vs. `Error` (return typed `Memory_unavailable` variant up the chain instead of empty summary).
- `recall_candidates_with_history` callers — same pattern.

The existing `MemoryRecallReadErrors` counter is retained as a *secondary* observability signal but is no longer the only signal — the typed boundary forces caller branches to handle `Error` explicitly.

**Sunset criterion**: When the typed `result` signature is in place and all caller sites consume it via `match`, the counter is reclassified from "load-bearing" to "informational" and the WARN-once log is removed. The counter itself can remain (cardinality bounded by `exn_class`) for long-tail trend analysis.

### 3.2 `saved_tokens` / `saved_messages` — phantom-typed pre/post counts (replaces #16778)

Current code computes `max 0 (tok_count - new_tok_count)` and emits `CompactionNegativeSavings` on the negative branch:

```ocaml
let new_tok_count = token_count compacted_ctx in
let saved_tokens = max 0 (tok_count - new_tok_count) in
```

The negative branch exists because `tok_count` and `new_tok_count` originate from the same function (`token_count`) applied to two different contexts — but the function is fundamentally an *estimate*, not a measurement. Two independent estimates can disagree.

Replacement: phantom type discriminates *pre-compact estimate* from *post-compact recount*:

```ocaml
module Token_count : sig
  type 'phase t = private int
  type pre   (* pre-compact estimate *)
  type post  (* post-compact recount *)
  val pre_estimate  : Context.t -> pre  t
  val post_recount  : Context.t -> post t
  val saved : pre:pre t -> post:post t -> [ `Saved of int | `Divergent of int ]
end
```

`saved` returns `Divergent` when `post > pre`. The compiler enforces that the pre/post arguments cannot be swapped, so the "two estimates of the same context" subcase becomes representable as `Divergent`. Callers must pattern-match — silent floor is no longer reachable.

**Sunset criterion**: When `Token_count.t` phantom types are introduced and `keeper_compact_policy.ml:312` consumes them via `match`, the `CompactionNegativeSavings` counter is removed. The `kind` label vocabulary (`tokens` | `messages`) is folded into `Divergent`-variant payload.

### 3.3 `resolve_live_with_catalog` — typed `Cascade_name.t` parse (replaces #16787)

Current code accepts `string` and silently falls back to `Keeper_turn` default for unresolved names:

```ocaml
val resolve_live_with_catalog :
  catalog:string list -> string -> string
```

Replacement applies "Parse, don't validate":

```ocaml
val resolve_live_with_catalog :
  catalog:string list -> string
  -> (Cascade_name.t, [ `Unresolved of string ]) result
```

Caller sites:

- `Keeper_cascade_profile.cascade_name_for_use` and downstream — branch on `Ok name` (use) vs. `Error (`Unresolved raw)` (boot-time error or operator-visible alert; never default-route).
- Tests assert that *no path* returns `Cascade_routes.fallback_name_for_catalog Keeper_turn ~catalog` for unresolved input.

**Sunset criterion**: When `Cascade_name.t` becomes the resolution boundary and `resolve_live` returns `result`, the `on_resolve_live_fallback` metric is removed and `logged_unresolved_raw` Hashtbl is removed. Operators see typed `Error` at config load time, not at turn time.

## 4. Removal targets

| Workaround | Removal target | Owner | Tracking |
|---|---|---|---|
| #16771 (memory recall counter+WARN) | RFC-0149 §3.1 implementation merged | TBD | This RFC |
| #16778 (compact negative_savings counter) | RFC-0149 §3.2 implementation merged | TBD | This RFC |
| #16787 (cascade resolve_live WARN-once) | RFC-0149 §3.3 implementation merged | TBD | This RFC |

No date pressure — the merged workarounds are observability-only and do not block production. They become *informational* (not load-bearing) once typed boundaries replace the silent paths.

## 5. Implementation order

1. **PR-1** — §3.3 first. `Cascade_name.t` typed parse. Smallest call-graph reach (cascade profile lookups only). Lowest risk.
2. **PR-2** — §3.1. `read_file_tail_lines` → `result`. Caller fan-out: 4 sites in `keeper_memory_recall.ml` + 1 in `keeper_memory_bank.ml`. Each caller adds an explicit `Error` arm.
3. **PR-3** — §3.2. Phantom-typed `Token_count.t`. Touches `Context.t` count source resolution. Wait for §3.1/3.2 to land first so the compaction pipeline review can include the boundary changes together.

Each PR adds tests asserting the typed boundary path is exercised and that the legacy silent-fallback site no longer compiles.

## 6. Non-goals

- This RFC does **not** revert PR #16771 / #16778 / #16787. The counters become informational, not load-bearing.
- This RFC does **not** demand a single mega-PR. The 3 root-fixes are independent and PR-able in any order; the order above is a recommendation, not a constraint.
- Other audit findings (B1-B6 above) are deferred to separate RFCs.

## 7. Lesson encoded into memory

`memory/feedback_telemetry_as_fix_self_recurrence.md` records the meta-lesson:

> Audit-driven counter / WARN fixes are themselves the very anti-pattern the audit identified. Before applying a counter or WARN to a silent path, the agent MUST check whether a typed boundary (Result.t / phantom type / closed-sum parse) is feasible at the call site, and prefer that. Counter-only fixes require Override 조건 (PR body `WORKAROUND:` label + replacement RFC + sunset target) at PR-creation time, not retroactively.

This RFC is the retroactive sunset; the feedback memory is the pre-PR check that should have prevented the need for it.

## 8. References

- `~/me/instructions/software-development.md` §AI 코드 생성 안티패턴 + §워크어라운드 거부 기준 §1 (텔레메트리-as-fix)
- `~/me/memory/masc-mcp-code-flowchart-audit-2026-05-20.html` (parent audit)
- `~/me/memory/feedback_telemetry_as_fix_self_recurrence.md` (lesson memory)
- RFC-0144 — Workaround Sunset Tracking for Keeper Dedup Carryovers (same meta-pattern, different cluster)
- RFC-0145 — Permissive Silent Fallback Elimination (same family of anti-patterns)
