# RFC-0199 Phase C — Implementation Design Memo

**Status**: Draft (design only; no code in this PR)
**Date**: 2026-05-27
**Builds on**: RFC-0199 ([#19132](https://github.com/jeong-sik/masc-mcp/pull/19132)) — Phase A ([#19157](https://github.com/jeong-sik/masc-mcp/pull/19157) merged) — Phase B ([#19206](https://github.com/jeong-sik/masc-mcp/pull/19206) open)
**Tracking**: [#19129](https://github.com/jeong-sik/masc-mcp/issues/19129)
**Goal**: design the wiring between [`Deterministic_evidence_evaluator`](../../lib/cdal/deterministic_evidence_evaluator.mli) (Phase B) and the existing [`Cdal_evidence_gate.decide`](../../lib/cdal_evidence_gate.mli) (RFC-0109) so that submit_for_verification auto-transitions when typed evidence is satisfied — *without* re-implementing the gate, the verdict store, or the transition FSM.

---

## 1. Hook point — confirmed by source

```
tool_task.ml:378
  Cdal_evidence_gate.decide
    ~task_id
    ~task_opt
    ~notes
    ~handoff_context
    ()
```

`decide` takes an optional `~lookup : task_id:string -> Cdal_types.contract_verdict option` defaulting to `Cdal_verdict_gate.lookup_latest_verdict`. **Phase C wiring lives entirely in the `lookup` chain — no change to `decide` itself, no new branch in `tool_task.ml`.**

### Layered lookup

```
Cdal_evidence_gate.decide
  └── lookup_with_evaluator_fallback ~task_id
      ├── 1. Cdal_verdict_gate.lookup_latest_verdict ~task_id
      │     (existing — verifier judgment, persisted to dated_jsonl)
      │     Some v → return v
      │     None   → fall through
      └── 2. Deterministic_evidence_evaluator.evaluate
              ~deps:production_deps
              ~claims:(task.contract.required_evidence_typed)
            All_satisfied
              → Some (synthesize_satisfied_verdict ~source:"auto_evaluator")
            Partial { missing }
              → Some (synthesize_inconclusive_verdict ~required_evidence:(render missing))
            Inconclusive { transient = true }
              → None (gate falls through, caller retries on next submit)
            Inconclusive { transient = false; reason }
              → Some (synthesize_inconclusive_verdict ~required_evidence:[reason])
```

Mapping notes:

- `All_satisfied → Satisfied verdict` → `Cdal_evidence_gate` row 1 → `Pass` → existing submit flow proceeds with `AwaitingVerification` (verifier sees pre-decided green, can auto-approve or veto).
- `Partial → Inconclusive verdict` with the missing claims rendered as `required_evidence` strings → `Cdal_evidence_gate` row 3b → `Reject` with `completeness_gaps`. Submitter receives structured `missing` list immediately.
- `Inconclusive transient=true → None` is the **important divergence**: do not synthesize a verdict at all so `Cdal_verdict_gate.gate_check` advisory path returns its existing "no verdict yet" state. The submitter is asked to retry. This avoids a synthetic `Inconclusive` poisoning future passes — the next submit re-evaluates, the CI may have completed, and the cycle resolves.

### Why lookup-augmentation, not pre-decide branching

Alternative considered: insert a `try_auto_approve` branch *before* `decide` in `tool_task.ml`. Rejected:

- Two transition paths to maintain (auto vs. verifier).
- Side-effect ordering (write synthetic verdict → transition → re-read verdict) is fragile.
- `decide` already encodes the full matrix; bypassing it duplicates the matrix.

Lookup-augmentation keeps the decide matrix as SSOT and reuses every Pass/Reject branch unchanged.

---

## 2. Production deps wiring

`evaluator_deps` (Phase B `.mli:81-89`) is the boundary. Production implementation per field:

### `gh_pr_check : repo:string -> pr_number:int -> pr_check_result`

- **Tool**: `gh pr view <pr> --repo <repo> --json mergedAt,state`
- **Sandbox**: same `masc_exec` argv path used elsewhere (`Exec_gate.run_argv_with_status_split` per RFC-0198) — no shell, typed argv.
- **Rate budget**: every submit triggers one `gh` call per `PR_merged | CI_pass` claim. With 33 backlog × ~2 PR claims/task = ~66 calls/burst. `gh_cache` (RFC-0109 `[gh_cache]` block, `cache_ttl_sec = 120`) is the reuse vector — Phase C wraps `gh_pr_check` with the existing cache.
- **Failure modes**: `gh` exit non-zero with `not found` → `Not_found`. Timeout (10s) → `Open` *or* a new `pr_check_result` variant? **Decision**: extend `pr_check_result` to `| Lookup_failed of string` only if the existing 4 variants prove insufficient — start without.

### `gh_ci_check : repo:string -> pr_number:int -> ci_check_result`

- **Tool**: `gh pr checks <pr> --repo <repo> --json bucket,name`
- Same sandbox path, same cache shape.
- Map: all buckets `pass` → `All_pass`; any `fail`/`cancel` → `Any_fail [names]`; any `pending` → `In_progress`; empty → `Not_found`.

### `exec_command : command:string -> timeout_sec:int -> exec_result`

- **Boundary**: this is the *highest-risk* dep. `command` is a free-form shell line declared at task creation. Phase C uses **keeper sandbox** with the same allowlist (`Dev_exec_allowlist`) — *not* host shell.
- **Restriction**: argv decomposition happens at task creation, not at evaluation. `task.contract.required_evidence_typed.Tests_pass` stores `command : string` for human readability but the typed argv pair (executable + argv list) lives alongside (decision pending — see §6 Open question).
- **Failure modes**: spawn fail → `Spawn_error msg`; timeout exhaustion → `Timeout`; exit code → `Exit code`. The 300s default in evaluator is for backstop only — `Tests_pass.command` should be quick (<60s) or the task author should split into multiple claims.

### `file_stat : path:string -> file_stat_result`

- **Tool**: `Unix.stat` — direct, no sandbox needed (read-only).
- **Boundary**: `path` is resolved relative to a *task-scoped root* — *not* the worker's cwd. Root is the task's worktree or the project root, depending on task type. **Decision pending** (§6).
- **Failure modes**: `ENOENT | EACCES` → `Missing` (collapse for the evaluator; both are "not satisfied"). EBUSY/EIO → propagate as `Inconclusive transient=true` via the aggregation, not via `file_stat` itself.

### `custom_check : id:string -> payload:Yojson.Safe.t -> custom_check_result`

- **Implementation**: registry of `string -> (payload -> result)` functions.
- **Allowlist**: maintained in `lib/cdal/custom_check_registry.ml` (Phase C new file). Unknown id → `Unknown_id` (Phase B's hard-inconclusive path).
- **Initial registrations**: empty. Each new check is a PR that adds an entry — never a config knob. Forces review of new check semantics.

---

## 3. Audit trail

Every synthetic verdict carries `~source:"auto_evaluator"` (vs. existing verifier-emit verdicts that carry the verifier's keeper name). Two consumers:

- **`dated_jsonl` verdict store**: same write path as verifier verdicts — `Cdal_verdict_gate.emit_verdict ~source`. New `source` value is opaque to existing consumers; dashboards filter on it explicitly when they care.
- **`task.task_history` / transition events**: `auto_approved : bool` is *not* needed as a separate field. The verdict's `source` field is sufficient — joining transition events with verdict rows by `task_id + timestamp` reveals the decision provenance. Avoids field duplication and keeps SSOT in the verdict store.

`masc_task_history` and dashboards already join these; no schema change in `Masc_domain.task`.

---

## 4. Verifier veto path

Spec (RFC body §"Verifier veto path"): auto-approved tasks (now in `Done`) can be rejected post-hoc by the verifier. Existing actions support this without new states:

- `transition reject` on a `Done` task → `Cancelled` (existing action available to verifier-role keepers). 
- **Decision pending**: do we need a new `Done_rejected` state (RFC body §"Verifier veto") to distinguish "complete-but-disputed" from "cancelled"? Concrete cost: new FSM state + every joining query + dashboard column. **Lean toward NO** — `Cancelled` with `cancel_reason="verifier_veto_post_auto_approval"` (or typed equivalent) is enough for now, and the verifier rarely vetoes auto-approved binary-deterministic tasks in practice. Revisit after Phase C ships if data shows >5% veto rate.

---

## 5. Phase C PR scope (proposed)

Single PR, target ~600 LOC. Stays small by:

1. **No new FSM states** (per §4 decision).
2. **No `Custom_check` allowlist content** — empty registry, follow-up PRs add checks.
3. **No migration codemod for `required_evidence : string list` legacy** — separate Phase B.5 PR (already deferred).
4. **No DX sugar** (RFC §"Phase D opt-in friction 완화") — Phase D PR.

Files (estimate):

| File | Change | LOC |
|---|---|---|
| `lib/cdal/evaluator_production_deps.ml` (new) | `gh_pr_check / gh_ci_check / exec_command / file_stat / custom_check` production impl | ~120 |
| `lib/cdal/evaluator_production_deps.mli` (new) | exported `make : unit -> Deterministic_evidence_evaluator.evaluator_deps` | ~10 |
| `lib/cdal/custom_check_registry.ml` (new) | empty registry skeleton | ~30 |
| `lib/cdal/custom_check_registry.mli` (new) | `register / lookup` API | ~10 |
| `lib/cdal/auto_verdict_synthesizer.ml` (new) | `evaluation_result → Cdal_types.contract_verdict option` mapping + lookup-augmenter | ~80 |
| `lib/cdal/auto_verdict_synthesizer.mli` (new) | exported `lookup_with_evaluator_fallback : task_id:string -> Cdal_types.contract_verdict option` | ~20 |
| `lib/tool_task.ml` | 1-line: `~lookup:Auto_verdict_synthesizer.lookup_with_evaluator_fallback` | +1 |
| `test/test_auto_verdict_synthesizer.ml` (new) | 4 mapping rules × edge cases + integration with stub evaluator | ~200 |
| `lib/cdal/dune` | wire new modules | +3 |
| `test/dune` | wire new test | +2 |

Total ~470 LOC + 10-line wire changes.

---

## 6. Open questions (block Phase C start)

1. **`Tests_pass.command` schema**: does `command : string` remain a human-readable hint with argv decomposition deferred to evaluator-side parsing, or does Phase A retro-extend to `command : { executable : string; argv : string list }`? Argv-typed is safer (sandbox enforced, no shell parse) but requires a Phase A follow-up PR. **Recommend argv-typed retro-extend** — RFC-0088 §"String 분류기" 일관.

2. **`file_stat` root resolution**: relative `path` resolves against what root? Three candidates:
   - (a) Task worktree (when `task.contract.links.session_id` resolves to a session with a worktree)
   - (b) Project root (`~/me/workspace/yousleepwhen/masc-mcp` for masc-mcp tasks)
   - (c) Explicit absolute paths only (reject relative at task creation)
   **Lean toward (c)** — explicit > implicit. Task author types `lib/types/evidence.ml` → reject; types `/Users/.../masc-mcp/lib/types/evidence.ml` → accept. Cost: more verbose task fixtures, but eliminates "resolved from wrong root" surprise.

3. **`gh_pr_check` cache integration**: reuse existing `gh_cache` (RFC-0109 `[gh_cache]`) verbatim, or build a separate `evaluator_cache` with different TTL? **Lean reuse** — single cache means single invalidation path, single hit-rate metric.

4. **`auto_verdict_synthesizer` write-through**: when evaluator returns `All_satisfied`, do we *write* the synthetic verdict to `dated_jsonl` (audit trail persisted) or only return it in-memory (caller logs as needed)? **Lean write-through** — uniform audit story (every Pass/Reject decision is replayable from the verdict store); cost is one append per submit.

5. **Veto path FSM**: `Cancelled` reuse vs new `Done_rejected` (per §4) — final call after Phase C ships and we observe veto rate.

These five blockers are *intentionally* not resolved in this memo. Each is a small standalone decision; the actual PR can split them across two sub-PRs if needed (e.g., argv-retro-extend first as a Phase A.5 PR, then the rest of Phase C).

---

## 7. Anti-pattern guards (CLAUDE.md §Workaround Bar)

| Guard | Phase C compliance |
|---|---|
| Counter-as-Fix | ❌ N/A — synthesizer emits *decisions*, not counters. Verdict store already exists. |
| String 분류기 | ❌ N/A — synthesizer maps closed sum `evaluation_result` → closed sum `contract_verdict`. No string match in the mapping. |
| N-of-M | ❌ N/A — all 5 deps wired in one PR. `Custom_check` registry empty in Phase C; subsequent checks are individual PRs (intended granularity, not N-of-M). |
| cap/cooldown/dedup/repair | ❌ N/A — transient retry is the typed `Inconclusive transient=true` path (no magic timeout). |
| FSM sparse match | ❌ N/A — reusing existing matrices in `Cdal_evidence_gate.decide`; no new states. |

---

## 8. Phase D preview (not in this memo)

Phase D layers on Phase C:

- `masc_add_task` DX: extract `evidence: pr#19108, ci#19108` from task description into typed `required_evidence_typed`.
- `verifier_required: true` opt-out flag for tasks that have deterministic evidence but want human judgment anyway.
- Throughput re-baseline for `verifier` persona (judgment-only tasks); separate issue.

Phase D is independent of cdal coupling. The `task_state_probe` gate (PR #19210, currently held) is *not* a Phase D dependency — its design (executable allowlist + cdal coupling decision) is orthogonal.

---

## Decision request

Resolve §6 questions 1-4 (question 5 deferred). Question 1 (argv-typed `Tests_pass`) is the only one that re-opens Phase A — call it explicitly so the Phase A.5 PR can land before Phase C starts.
