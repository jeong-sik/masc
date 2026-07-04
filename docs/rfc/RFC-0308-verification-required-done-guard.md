---
rfc: "0308"
title: "Verification-required done guard — route verifier-bound tasks through submit_for_verification"
status: Draft
created: 2026-07-04
updated: 2026-07-04
author: vincent
supersedes: []
superseded_by: null
related: ["0222", "0109", "0199", "0221", "0220"]
implementation_prs: []
---

# RFC-0308: Verification-required done guard

Status: Draft · Completion-policy convergence · Close the "no-verifier done" bypass
Drafted by: Claude (5-agent adversarial audit `wf_369a757f-334`, 2026-07-04), pending owner review.
Diagnosis source: code-level audit of `lib/mcp_server.ml`, `lib/workspace/workspace_task_lifecycle.ml`, `lib/keeper/keeper_tool_task_runtime.ml`, `lib/cdal_evidence_gate.ml`, `lib/task/tool_task.ml`, `lib/task/anti_rationalization.ml`.

> Anchors marked **(verified)** were read against the working tree on 2026-07-04. The audit traced every `task → Done` path.

---

## §1 Problem — `done` transitions bypass the verifier entirely

A keeper can move a task `claimed/in_progress → done` with **no verifier involvement**, structurally. Four independent bypass paths were confirmed by adversarial audit (each with code citation):

1. **`done` FSM transition has guard `None`** (`lib/mcp_server.ml:423` **(verified)**: `("done", ["claimed"; "in_progress"], "done", None)`). By contrast `submit_for_verification`/`approve`/`reject` carry `Some` guards (lines 428-430). The `done` path is **not connected** to the verification FSM at all.
2. **`Done_action` lifecycle arm ignores `verification_enabled`** (`lib/workspace/workspace_task_lifecycle.ml:145-152` **(verified)** — the `Claimed`/`InProgress → Done` arm checks `owner_authorized` only; it never reads the `verification_enabled` flag that the `Submit_for_verification` arm reads at lines 186-200). A task cannot reach `AwaitingVerification` via `done`.
3. **`keeper_task_done` hardcodes `action="done"`** (`lib/keeper/keeper_tool_task_runtime.ml:893` **(verified)**), and `lib/keeper/` contains **zero references to `submit_for_verification`** (verified by `rg -c`). The cross_verifier agent/runtime lane is therefore **never invoked** on the keeper's default `claim → start → done` flow. This is the code-level root cause of the "no-gate done" pattern recorded in memory.
4. **Contract-less tasks pass both the CDAL evidence gate and the persisted-contract gate** (`lib/cdal_evidence_gate.ml:199-202` **(verified)**: `| _ -> Pass` with comment *"a task with no contract has nothing to verify, so the gate must not block keeper_task_done"*; `lib/task/tool_task.ml:384-393` **(verified)**: persisted gate is `None` when no contract). Because `masc_add_task`'s `contract` argument is optional (`lib/task/tool_task_args.ml:11`), the majority of tasks have `contract = None` and bypass both gates simultaneously.

The only live gate on the `done` path is the anti-rationalization LLM reviewer, and it **fails open** by default (`lib/task/anti_rationalization.ml:1033-1044` **(verified)**: LLM-unavailable + `mode=open` → `Approve`; default `MASC_ANTI_RATIONALIZATION_FAIL_MODE=open` at `lib/config/env_config_governance.ml:188`). When the evaluator runtime is down or no provider is configured, even that gate silently approves. `keeper_task_done` does not pass `evaluator_runtime` (`lib/keeper/keeper_tool_task_runtime.ml:890-897`), so the default runtime is used.

**Net effect:** a keeper producing 20+ chars of descriptive `result` reaches `done` with **zero verifier calls**. The verifier subsystem exists but is unreachable on the default path. This is the pattern repeatedly observed in operation logs ("P0 9건 무게이트 done 실적").

---

## §2 Design — conditional `done` guard (the only root close)

The audit evaluated four candidate fixes; only **(a)** closes the bypass:

- (a) **Strengthen the `done` transition guard** (this RFC) — *root*.
- (b) Apply the CDAL evidence gate to `done` too — **insufficient**: the gate is a lexical substring match (`lib/cdal_evidence_gate.ml:38-54`), and `required_evidence` text typed into `notes` passes it; file-based evidence is explicitly `false` (lines 30-35). This is the CLAUDE.md workaround-signature §2 ("string classifier") and is not a root fix.
- (c) Narrow the contract-less bypass — **insufficient**: tasks *with* a contract still allow `claim → start → done` (gate is `needs_gate = false` for `Done_action`, `tool_task.ml:441-454`).
- (d) Flip the FSM default on — **non-fix**: the FSM default is already `true` (`lib/config/feature_flag_registry.ml:223`), but the `done` path does not traverse the FSM, so the flag has zero effect on it.

### §2.1 The guard is conditional, not unconditional

An unconditional `done → submit` redirect would break two intentional designs and is rejected:

- **RFC-0199 deterministic-harness auto-done** (`lib/keeper/keeper_tool_task_runtime.ml:670-699`): when `evidence_claims` are all satisfied by `Keeper_deterministic_evidence_probe`, the harness force-completes the task (System authority). This is an intentional deterministic backstop and must remain.
- **Liveness guarantee** (RFC-0109 Phase D, `lib/task/tool_task.ml:434-437`): *"a normal done action must not depend on the verifier agent being alive."* A hard verifier dependency would deadlock a single-keeper workspace where no other process serves the cross_verifier lane.

Therefore the guard routes only **verifier-required** tasks to `submit_for_verification`:

> A task is **verifier-required** iff its `contract.completion_contract` is non-empty **OR** its goal's `verifier_policy` is non-`None`.

For verifier-required tasks, the `claimed/in_progress → done` transition is **removed from the FSM**; the only completion transition is `submit_for_verification → awaiting_verification → (verifier) approve/reject`. For non-verifier-required tasks (no contract, no goal policy), the current `done` path is preserved unchanged (liveness + RFC-0199 harness intact).

### §2.2 Type-level invariant (parse, don't validate)

The current topology — `done` and `submit_for_verification` as sibling actions the agent picks between — is itself the root defect. RFC-0308 makes the FSM **task-policy-dependent**: the transition table is computed per task from its verifier-required flag, so a verifier-required task's FSM literally does not contain the `in_progress → done` edge. The illegal transition is unrepresentable.

---

## §3 Relationship to existing RFCs

- **RFC-0222** (typed acceptance criterion + harness-driven completion, Draft): complementary. RFC-0222 adds a *deterministic* completion path for checkable tasks (acceptance criterion satisfied → auto-done). RFC-0308 adds the *inverse*: verifier-required tasks **cannot** be done directly. Together: checkable → harness auto-done; verifier-required → submit-forced; everything else → current `done`. RFC-0308 does not supersede RFC-0222; the two compose.
- **RFC-0109 Phase D** (`tool_task.ml:434-437` "must not depend on verifier agent being alive"): **amended in part**. The liveness guarantee is preserved for non-verifier-required tasks. For verifier-required tasks, the guarantee is intentionally narrowed — those tasks opt into a verifier dependency by carrying a contract/policy. This is a scoped exception, not a wholesale removal.
- **RFC-0199** (evidence-driven auto-approval): preserved. The deterministic-harness auto-done path (`670-699`) is an explicit exception in the per-task FSM computation; it does not traverse the guard.
- **RFC-0221** (atomic verification submission) / **RFC-0220** (verification scheduling decouple): unaffected — they operate on the `awaiting_verification` side, which RFC-0308 makes reachable for verifier-required tasks.

---

## §4 Implementation sketch

1. **`lib/mcp_server.ml:419-431`** — `task_fsm_transitions` becomes a function of task policy. For verifier-required tasks, the `("done", ["claimed"; "in_progress"], ...)` row is removed; only `submit_for_verification` leads to completion. For others, the table is unchanged.
2. **`lib/workspace/workspace_task_lifecycle.ml:145-152`** — the `Done_action` arm reads `is_verifier_required task` and rejects with `Error Verification_required_use_submit` when the task is verifier-required (mirrors the `Submit_for_verification` arm's `verification_enabled` check at 186-200).
3. **`lib/task/tool_task.ml`** — `is_verifier_required : Masc_domain.task -> bool` derived from `contract.completion_contract` non-empty OR goal `verifier_policy` non-None. `needs_gate` for `Done_action` becomes `true` when verifier-required.
4. **`lib/keeper/keeper_tool_task_runtime.ml:893`** — `keeper_task_done` chooses `action="submit_for_verification"` when the task is verifier-required (and `action="done"` otherwise). The keeper no longer needs to *decide*; the runtime routes correctly by policy.
5. **Anti-rationalization gate** — out of scope for this RFC, but flagged: the fail-open default (`mode=open`) means even the live `done` gate is weak for non-verifier-required tasks. A follow-up RFC should consider `fail_mode=closed` for verifier-required paths, or routing those through `submit` (which this RFC does) so the fail-open gate is no longer the last line.

---

## §5 Compatibility & migration

- **High risk on the default flow.** `claim → start → done` is documented as the normal completion flow (`lib/task/tool_task_schemas.ml:33`). The conditional guard preserves it for non-verifier-required tasks (the majority, since `contract` is optional today), so the blast radius is limited to tasks that *opt in* to a contract or whose goal sets a `verifier_policy`.
- **RFC-0199 harness auto-done** is preserved as an explicit policy exception.
- **Single-keeper workspaces** with no cross_verifier serve process: verifier-required tasks will block at `awaiting_verification` until a verifier acts (or the TTL `check_timeouts` rejects — `verification_protocol.ml:125-130`). Operators who set `verifier_policy` are opting into this; the TTL prevents permanent stall.
- **Goal-level propagation**: `require_completion_approval` defaults to `false` (`lib/goal/goal_store.ml:620`) and `verifier_policy` is optional. Only goals that explicitly set these trigger verifier-required task routing.

---

## §6 Tests

- Verifier-required task (`contract.completion_contract` non-empty): `claim → start → done` is **rejected** (`Verification_required_use_submit`); `claim → start → submit_for_verification` is the only completion path.
- Verifier-required task (goal `verifier_policy` non-None, no task contract): same rejection.
- Non-verifier-required task (no contract, no goal policy): `claim → start → done` succeeds (unchanged).
- RFC-0199 harness auto-done: verifier-required task whose `evidence_claims` are all satisfied still auto-completes (policy exception).
- FSM transition table per-task: a verifier-required task's computed table contains no `in_progress → done` edge.

---

## §7 Open questions

1. Should the anti-rationalization gate's `fail_mode` default flip to `closed` for verifier-required tasks (defence in depth), or is routing through `submit` sufficient? (Audit suggests routing is sufficient; fail_mode is a separate concern.)
2. The `persisted_contract_rejection` gate was flagged as a dead no-op (`tool_task_contract_gate.ml:66-76` always returns `None`) — should RFC-0308 also revive it, or is it intentionally inert pending another RFC?
3. Cross_verifier lane serving in a single-process keeper: does the same process that owns the task serve the verifier lane (self-verification risk)? The `Submit` arm blocks `same_agent → Self_approval`, but the `done`-path LLM gate does not. This audit did not fully trace the lane serving; follow-up verification needed.

---

## §8 Status

Draft. Pending owner review. Implementation PRs to be listed in `implementation_prs` once approved. This RFC is gated by CLAUDE.md `agent_delegation` (verification protocol subsystem) — push requires RFC citation in PR body.
