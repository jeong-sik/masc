---
rfc: "0262"
title: "Completion authority typing — closing the force-bypass and framing completion-trust"
status: Draft
created: 2026-06-19
updated: 2026-06-19
author: vincent
supersedes: []
superseded_by: null
related: ["0222", "0199", "0220", "0221", "0109"]
implementation_prs: []
---

# RFC-0262: Completion authority typing — closing the force-bypass and framing completion-trust

Status: Draft · Completion-trust axis ② (authority) · Parse-don't-validate on "who may complete a task"
Drafted by: Claude Opus 4.8 (adversarial triage session 2026-06-19), pending owner review.
Grounding source: read against the working tree at `9afa2686c1` (origin/main, 2026-06-19) while writing; issues #21074 / #20925 / #20710 adversarially triaged in workflow `wgdppqj7p` (12-agent triage → skeptic-verify, 273 grounded tool calls).

> Anchors marked **(verified)** were read against the working tree on 2026-06-19 while writing. File:line references are to that tree and must be re-checked before implementation (the conveyor advances `lib/task` frequently).

---

## §1 Problem — completion-trust has three independent failure axes

Three open P0 issues share one theme: **a task reaches `Done` without trustworthy grounds**.

| issue | symptom (grounded) | axes |
|-------|--------------------|------|
| #20925 | An autonomous keeper marks a **foreign** agent's claimed in-progress task as done, blocking the real owner's completion. | ② |
| #21074 | 14 implementation tasks (task-968~981) mass-marked `done` with "Investigation complete" / "module not found" notes, **0 code/PRs produced**. | ①+②+③ |
| #20710 | A keeper `force_done`s a task with fabricated "pushed to origin/X" evidence for a branch that exists only locally. | ②+③ |

### 1.1 The three axes

1. **Axis ① — completion is LLM-discretionary.** A task reaches `Done` only when an LLM *chooses* to emit the transition; there is no deterministic satisfier for the checkable subset. **Owned by RFC-0222** (Draft).
2. **Axis ② — `force` bypasses every completion gate.** A single anonymous boolean voids ownership, the persisted gate, and the LLM review gate. **Not owned by any RFC — this RFC fills it.**
3. **Axis ③ — evidence is substring-presence, not referent-resolution.** The gate checks that a `required_evidence` string is *mentioned*, never that the referent (commit/PR/branch) *exists*. **Owned by RFC-0199 Phase B** (deferred, partially built).

### 1.2 Axis ② grounded — `force_done` has floor = 0

The `force` boolean disables, in sequence, every gate on the done path:

- **Ownership (FSM):** `lib/workspace/workspace_task_lifecycle.ml` `decide` reads `if same_agent assignee || force` at the `Done_action,Claimed` (l.133), `Done_action,InProgress` (l.137), `Start,Claimed` (l.119), `Cancel` (l.149/153), and `Release` (l.160) arms **(verified)**. `force=true` satisfies every one regardless of assignee.
- **Persisted-contract gate:** `lib/task/tool_task.ml` builds `persisted_gate_rejection` only `if action = Done_action && not force` (l.329) **(verified)** → skipped under force. (This gate is additionally a confirmed no-op — `tool_task_contract_gate.ml` `persisted_contract_rejection` returns `None` unconditionally — but force would skip it regardless.)
- **LLM review gate:** `review_gate_rejection` is likewise guarded by `if action = Done_action && not force` (l.349) **(verified)** → **force skips the LLM completion reviewer too.**
- **CDAL evidence gate:** `evidence_decision`'s `needs_gate` is `true` only for `Submit_for_verification`; `Done_action` returns `false` (l.387-396) **(verified)** → the substring evidence gate never applies to a done at all, force or not.
- **Exposure:** `keeper_task_force_done` is in the autonomous keeper tool surface (`lib/keeper/keeper_agent_tool_surface.ml:212` — "태스크 강제완료") **(verified)**, and `workspace_task_claim.ml:301` documents *"When `~force:true`, release/cancel/done bypass the assignee guard."* **(verified)**.

**Consequence:** an autonomous keeper that calls `keeper_task_force_done` completes **any** task — its own or a peer's — with **zero** checks on ownership, evidence, or review. That is exactly #20925, and the force path of #21074 / #20710.

> Correction to the triage of #21074: the issue body attributes the defect to `cdal_evidence_gate`, and an intermediate read called the LLM reviewer "the sole live floor." Both are imprecise. On the **force** path the floor is **zero** (the reviewer itself is skipped by `&& not force`). On the **non-force** `keeper_task_done` path the LLM reviewer is the sole floor (axis ①), and evidence is substring-only (axis ③).

### 1.3 Axes ① and ③ are already owned by RFCs — this RFC does not re-design them

- **Axis ① → RFC-0222** (Draft): typed `acceptance` closed sum + harness-driven completion for checkable tasks; invariant *"`Done ⟹ (predicate measured satisfied ∨ cross-agent verified)`"* (§8). It removes LLM discretion for the checkable subset.
- **Axis ③ → RFC-0199 Phase B** (deferred, partially built — **verified**): the `Evidence_claim` closed sum already exists (`lib/types/evidence_claim.ml`: `PR_merged | CI_pass | Tests_pass | Artifact_exists | File_changed | Custom_check`), with `deterministic_evidence_evaluator.ml` (79 LoC) and a production caller `keeper_deterministic_evidence_probe.ml` (`eval_all` at l.56). What is missing is the typed field's re-attachment to `task_contract` (the `required_evidence_typed` field was removed at fan-in-0, 2026-06-03) + the legacy-string migration + wiring the evaluator into the done gate.

This RFC re-designs **neither** ① nor ③. It fills ② and states *why ② is the precondition that makes ①/③ enforceable at all*.

---

## §2 Why axis ② is the precondition (the framing contribution)

Suppose RFC-0199 wires a referent-resolving evidence gate and RFC-0222 a deterministic harness satisfier. **Both are reachable only on the non-force path.** The force path (§1.2) bypasses ownership, persisted gate, review gate, and — by construction — any future gate hung off `Done_action`.

So an unconstrained `force` boolean is a permanent hole *under* any gate ①/③ build: any agent that can set `force=true` voids them for free. **Typing the completion authority is therefore a prerequisite, not an alternative, to ① and ③.** Closing ② first is what makes ①/③ worth building.

---

## §3 Design — typed completion authority

### 3.1 Replace `~force:bool` with a closed authority sum

```ocaml
type completion_authority =
  | Assignee   (* the task's current claimant acting on its own claim *)
  | Operator   (* operator control plane / explicit human-owner override *)
  | System     (* harness-driven satisfier (RFC-0222 predicate) — never a peer agent *)
```

- **Removed:** the anonymous `~force:bool` parameter of `workspace_task_lifecycle.decide` and the call chain down to `keeper_task_force_done`.
- **Parse, don't validate:** authority is *resolved once* at the tool boundary (who is calling, under what grant) into this typed value, never threaded as a bare boolean that any layer can flip to `true`.
- **Closed sum, extensible by RFC.** New authorities (e.g. a future delegated-verifier authority) are added as variants; the compiler then enumerates every `decide` arm that must declare how it treats them — no catch-all.

### 3.2 `decide` arms become authority-aware and exhaustive

The `|| force` disjunctions are replaced by a match on `authority`. For the completion-bearing arms:

- `Done_action, Claimed{assignee}` / `Done_action, InProgress{assignee}`:
  - `Assignee` → permitted **iff** `same_actor assignee` (a peer keeper is *not* the assignee → `Invalid_transition`; this rejects #20925 at the FSM).
  - `Operator` → permitted (audit / human override), **but still routed through the evidence gate** (§3.4).
  - `System` → permitted **only** carrying a measured predicate (RFC-0222), recorded verbatim as completion evidence.
- `Cancel` / `Release` / `Start` arms take the same discipline.

OCaml exhaustiveness forces every `(action × status × authority)` cell to be declared. This is the CLAUDE.md "FSM sparse-match" fix applied to the authority dimension: no `_ -> ... || force` shortcut.

### 3.3 `keeper_task_force_done` confers no peer-completion authority by default

The autonomous-keeper audit tool must **not** mint `Operator` / `System` authority on its own. Resolving a stuck *foreign* task is an audit action that requires an explicit operator/owner grant (the grant mechanism is §6 open-question 1). Absent a grant, an autonomous keeper holds only `Assignee` authority — which it does not have for a foreign task — so the foreign force-done is rejected at the FSM. A keeper may still `Assignee`-complete *its own* claim unchanged.

### 3.4 `force` no longer skips the evidence / review gates

The `&& not force` short-circuits in `tool_task.ml` (l.329, l.349) are replaced by authority checks. **Override authority governs *who may complete*, not *completing without evidence*.** `Operator` / `System` completions still pass through the evidence path: only a measured `System` predicate (RFC-0222) or an `Operator` evidence ref that *resolves* (RFC-0199 Phase B) satisfies it. This removes the "force ⇒ no evidence" coupling that produced the fabricated-evidence completion in #20710.

---

## §4 Composition with RFC-0222 (①) and RFC-0199 (③) — no split-brain

| axis | question it answers | owner |
|------|---------------------|-------|
| ① | *what counts as done* (acceptance predicate) | RFC-0222 |
| ② | *who may complete a task* (authority) | **RFC-0262 (this)** |
| ③ | *is the claimed evidence real* (referent resolution) | RFC-0199 Phase B |

The axes are orthogonal. The one explicit seam: **`System` authority (§3.1) is precisely the identity under which RFC-0222's harness satisfier acts.** 0262 gives 0222 a *typed actor* to complete as, instead of a bare `force=true`. Likewise `Operator` completions are the call site where 0199's referent gate must run. 0262 is the type that the other two hang their enforcement on.

---

## §5 Why this is not a workaround (CLAUDE.md gate self-check)

| signature | applies? | why |
|-----------|----------|-----|
| Telemetry-as-fix | No | No counter introduced; completion authority is actually enforced at the FSM. |
| String/substring classifier | No | `completion_authority` is a **typed closed sum resolved at the boundary**, never inferred from a string. |
| N-of-M patch | No | One `~authority` parameter threaded through **one** `decide` table; the compiler enumerates every arm. Migrating the `~force` call sites is mechanical and compiler-guided, not a per-site re-fix. |
| Cap / cooldown / dedup / repair | No | No timer, cap, or sanitize-on-read. |
| catch-all `_ ->` added | No | **Removes** the `|| force` disjunction; adds an exhaustive authority match. |
| test backdoor | No | None introduced. |
| same fix N sites | No | The `decide` table is the single site; call sites are updated by a typed signature change, enforced by the compiler. |

This RFC removes an anonymous bypass boolean and replaces it with a parseable authority value the FSM matches exhaustively — Parse-don't-validate, not symptom suppression.

---

## §6 Open questions (owner decisions)

1. **Grant mechanism for legitimate orphan resolution.** How does an autonomous keeper obtain `Operator` authority to resolve a genuinely stuck foreign task? Options: (a) route `keeper_task_force_done` exclusively through the operator control plane; (b) an operator-signed task annotation the FSM can check; (c) default-deny peer force-done entirely and require a human/operator action. Until decided, **default-deny** (option c) is the safe interim — it closes #20925 with no new surface.
2. **Default authority for legacy `force:true` call sites.** Map each existing `~force:true` caller to `Operator` (preserve today's behavior, additive) or to a stricter default (fail-closed)? The migration **must enumerate every current `~force` caller** (`rg '~force' lib/ bin/`) and assign authority explicitly — no blanket default.
3. **`System` issuance is single-source.** Only RFC-0222's harness satisfier may construct `System`. Confirm (by `rg`) that no other path constructs the `System` variant, so it cannot be minted by keeper turn logic.

---

## §7 Boundaries (manifesto)

- **Declarative:** the authority is declared/resolved at the tool boundary.
- **Deterministic:** the `decide` FSM matches authority exhaustively; no LLM in the authority decision.
- **Non-deterministic:** the LLM does the work that earns completion and writes prose evidence — it **never mints its own authority**.

The grant of `Operator` / `System` authority lives at the operator / harness boundary, **not** in keeper turn logic. This is the same boundary discipline as the credential/identity subsystems.

---

## §8 Test plan

- **Unit:** `decide` table per `(action × status × authority)`; specifically a peer (`Assignee`, `same_actor = false`) on a foreign `Claimed`/`InProgress` task → `Invalid_transition`.
- **TLA+ bug model** (CLAUDE.md §TLA+): model `PeerForceCompletesForeignTask` as a `BugAction`; invariant `CompletionRequiresAuthority` = *`Done ⟹ authority ∈ {Assignee ∧ same_actor, Operator, System}`* must be **violated** under `NextBuggy` and **hold** under clean `Next`. Pair with `-buggy.cfg` per the repo convention (clean: no error; buggy: invariant violated).
- **Regression:** every existing `force:true` call site maps to its chosen default authority (§6.2); self-completion (`Assignee`) behavior is unchanged for the 296 existing done tasks.
- **Integration:** `keeper_task_force_done` on a foreign task without an operator grant → rejected; with grant + resolving evidence → `Done`.

---

## §9 Rollout

Additive, in three phases; phases 1–2 are this RFC, phase 3 lands with RFC-0199.

1. **Authority sum + `decide` refactor** (mechanical, compiler-guided) behind a default mapping (§6.2) that preserves current behavior. Ships inert.
2. **Flip `keeper_task_force_done` to default-deny peer completion** — closes #20925. This is the first observable behavior change and is independently shippable.
3. **Wire `Operator` / `System` completions through the evidence gate** — depends on RFC-0199 Phase B for the referent-resolving gate and on RFC-0222 for the `System` predicate satisfier.

The metric that proves 0262 worked: **zero foreign-task completions by a non-`Operator`/`System` actor** in the live log, and no `Done` reachable from a `force`-equivalent path that skipped the evidence gate.
