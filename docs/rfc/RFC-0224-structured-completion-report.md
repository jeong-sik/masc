---
rfc: "0224"
title: "Structured completion report for free-text contract items"
status: Draft
created: 2026-06-10
updated: 2026-06-10
author: vincent
supersedes: []
superseded_by: null
related: ["0220", "0221", "0222"]
implementation_prs: []
---

# RFC-0224: Structured completion report for free-text contract items

Status: Draft · Subjective-lane companion to RFC-0222 · Parse-don't-validate on "did you address each obligation"
Drafted by: Claude Fable 5 (operator-supervised keeper-PR disposition session 2026-06-10), pending owner review.

> Anchors marked **(verified)** were read against the working tree / live logs on 2026-06-10 while writing.

---

## §1 Problem — the contract gate checks lexical overlap, and its deterministic half is dead

A task may pre-declare a `completion_contract : string list` (free-text checklist). At `done`, the system must decide whether the completion notes address each item. Today that decision has two layers:

1. **Legacy local gate** `check_contract` (`anti_rationalization.ml:595` **(verified)**): case-insensitive *substring* match of each item against the notes. The doc comment calls it "deliberately simple".
2. **Gate 3 LLM review**: when the verification FSM is enabled, the contract travels into the LLM prompt and the legacy gate is skipped entirely (`anti_rationalization.ml:705` **(verified)**: `if Env_config_runtime.Verification.fsm_enabled () then None else …check_contract…`).

Facts about the current state **(verified 2026-06-10)**:

- `MASC_VERIFICATION_FSM_ENABLED` default = `true` (`feature_flag_registry.ml:197-200`, since 0.9.3).
- The legacy gate's only firing signature (`"contract unmet (legacy)"` / `"completion contract not satisfied"`) appears **0 times** in June `<base-path>/.masc/logs/system_log_*.jsonl` — the substring gate is dead on the production path.
- PR #20699 (closed 2026-06-10) added a word-boundary token fallback to the dead gate, claiming to fix the task-716 rejection cycle. The matching predicate was well-built and tested, but it strengthened a string classifier (CLAUDE.md workaround signature #2) on a path that never executes; the actual task-716 rejections came from the live Gate 3 / evidence-gate lane.

The structural defect, independent of which layer fires: **the producer's claim of contract satisfaction is inferred from prose** — by substring in the dead lane, by an LLM reading unstructured notes in the live lane. A keeper can rationalize by silence: notes that simply never mention an obligation force the judge to infer the omission. That inference step is where both the false-reject churn (task-716 style) and the rationalization risk live.

## §2 Scope boundary vs RFC-0220 / 0221 / 0222 (no split-brain)

| Concern | Owner |
|---------|-------|
| Verification-state atomicity | RFC-0221 |
| Scheduling / liveness / guaranteed verifier satisfier | RFC-0220 |
| **Checkable** tasks: machine-measurable acceptance predicates, harness-as-satisfier | RFC-0222 |
| **Subjective** tasks: how the producer's contract-satisfaction *claim* is carried and gated | **This RFC (0223)** |

RFC-0222 §6.1 states it "does **not** solve subjective non-convergence" and leaves `Manual_review` tasks on the existing prose path. 0223 is that lane's producer-protocol fix. The two compose per task: a checkable predicate (`acceptance`, 0222) and a free-text checklist (`completion_contract`, 0223) can coexist; 0222's `Manual_review` population is exactly 0223's beneficiary set. Truth-judgment stays with Gate 3 LLM + RFC-0220 §3.5 verifier — 0223 does not move it.

## §3 Design — declare per-item, gate completeness, judge semantics

### 3.1 Typed report at the completion boundary

```ocaml
type completion_item_status =
  | Met
  | Not_applicable   (* with justification in [evidence] *)

type completion_report_entry = {
  item_index : int;   (* index into the task's completion_contract *)
  status : completion_item_status;
  evidence : string;  (* non-empty: what was done / why N/A; may carry refs (PR#, path, log) *)
}
```

`masc_transition(action=done)` and `keeper_task_done` (both producer surfaces) gain an optional `completion_report : completion_report_entry list`. When the task's `completion_contract` is non-empty, the report is **required** (flag-gated rollout, §7).

There is deliberately no `Not_met` variant in the done-path report: a producer that knows an obligation is unmet must not call `done` — the existing `release` with `handoff_context` (RFC-0220 lane) is the honest exit, and the gate's rejection message says so.

### 3.2 Deterministic gate: completeness, not content

The gate replaces `check_contract` and performs **zero string matching against notes**:

- bijection: every contract index covered exactly once, no unknown indices;
- every entry's `evidence` is non-empty after trim.

Total function over typed input; rejection enumerates exactly the missing/duplicate indices and quotes the corresponding contract items — an actionable message instead of "notes don't contain substring X". This gate runs in both FSM-on and FSM-off deployments (it needs no LLM), which is what makes the legacy substring matcher deletable rather than kept as a fallback.

### 3.3 Semantic layer unchanged, better fed

Gate 3's prompt receives the structured triples (item, claimed status, evidence) instead of inferring coverage from prose. The judge's question collapses from "do these notes happen to address item 3?" to "is this specific evidence for item 3 credible?" — a strictly easier judgment with less false-reject surface. RFC-0220's cross-agent verifier sees the same structure on `AwaitingVerification`.

### 3.4 Why this kills the rationalization-by-silence pattern

Today an obligation can be skipped by simply not mentioning it; the omission is only as visible as the judge's attention. Under 0223, silence is a *gate* failure (missing index — deterministic), and evasion requires an explicit false `Met` claim with fabricated evidence — a discrete, attributable lie that the LLM judge, the verifier, and any later audit can target. The design converts an inference problem into a declaration protocol: parse, don't validate.

## §4 Workaround-gate self-check (CLAUDE.md signatures)

| Signature | Applies? | Why |
|-----------|----------|-----|
| Telemetry-as-fix | No | No counters; the gate changes what `done` accepts. |
| String/substring classifier | No — **negative delta** | Deletes `check_contract` (a substring classifier); adds a closed sum + index bijection. No matching of notes text anywhere. |
| N-of-M patch | No | One typed carrier, one gate; both producer surfaces converted in the same change (compiler-enforced via the shared transition path). |
| Cap / cooldown / dedup / repair | No | No timers or thresholds; nothing repaired on read. |
| catch-all `_ ->` | No | `completion_item_status` is a closed sum; matches stay exhaustive. |
| Test backdoor | No | None; tests construct reports through the public surface. |

## §5 Honest limits

1. **Truth is still not proven.** A false `Met` with plausible evidence passes the gate; semantic judgment remains with Gate 3/verifier by design. 0223 narrows the lie's shape; it does not eliminate lying. For provable obligations, declare an RFC-0222 predicate instead.
2. **Producer schema change.** Keepers must learn to emit the field. Structured tool arguments are empirically more reliable for LLMs than incidental prose phrasing, and the rejection message enumerates what is missing — but until prompts/tool docs are updated, a hard requirement would churn. Hence the flag (§7).
3. **Contract quality is upstream.** Vague contract items ("improve quality") produce vague evidence; 0223 cannot fix authoring. RFC-0222 §6.2's adoption argument applies symmetrically.

## §6 Open questions (owner decisions)

1. Require the report at `submit_for_verification` too (same gate), or only at `done`? Leaning yes — the verifier benefits most from the structure.
2. Should `Not_applicable` require a distinct justification field instead of overloading `evidence`? (Current lean: one field, the judge reads it either way.)
3. Delete `check_contract` in the same PR as the gate, or in a follow-up once the flag flips? (Current lean: same PR — it is dead in production now, and FSM-off gets the completeness gate as a strict replacement.)

## §7 Test plan & rollout

**Tests**: unit — bijection violations (missing index, duplicate, unknown), empty-evidence rejection, contract-less task passes without a report, FSM-off path runs the same gate; integration — `done` on a contracted task without a report rejects with the enumerated items and a release pointer; regression — existing contract-less flows byte-identical.

**Rollout**: additive field first (accepted when present, gate advisory) behind `MASC_COMPLETION_REPORT_REQUIRED` (default `false`) → update keeper prompts/tool docs → flip default to `true` → delete `check_contract` and its fallback lane. Success metric: contract-bearing tasks' done-rejection rate from the contract lane → ~0 false rejects (the task-716 class), with gate rejections that do occur being actionable (missing-index messages), measured over `system_log` before/after.
