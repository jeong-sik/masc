# Research-backed completion features

Status: plan and work records published; the first feature's controlled
[execution evidence](../evidence/goal-original-body-isolation-20261025.md) records
the reproduced failure and passing repair. No broader completion-rate improvement
is claimed.
Source census: `6505bd4fedb7e78121fda9a2195ced0a03f2c629`, 2026-10-25.

Adversarial follow-up found daemon admission starvation and missing current
original-read diagnostics outside the first worker checks. Their actual-daemon
[failure and repair receipts](../evidence/goal-daemon-progress-20261025.md) are
tracked by #45975 and task-2672 in three additional layers of the same stack.

The [delivery audit](../evidence/completion-feature-delivery-20261026.md) records
the requirement-by-requirement readback, current follow-up ownership, and the
subsequent whole-stack integration of a reviewed retained-recovery amendment.
Historical execution receipts keep their original source identities.

The requested outcome is a product that finishes the user's original work,
including correction after rejection and recovery after interruption. The operator
selected a first feature stack that repairs one demonstrated failure through
reverification and delivery, while recording all four research strands as work.
This plan refines [Reliable Change G1–G5](../RELIABLE-CHANGE-ROADMAP.md); it does
not replace those acceptance contracts or treat implementation activity as success.

## Research, behavior and existing work

| Strand | User-visible behavior and implementation boundary | Evidence of the gap and reuse | Acceptance |
|---|---|---|---|
| Rejection to correction | A Keeper receives the failed criteria, original artifact revision and actual review observations, corrects the artifact, resubmits and delivers the accepted result. Reuse the Task lifecycle, rejection outbox, original verification request and result publication. | Full rejection reason already reaches the next prompt. #45861 fixes actual stale-handoff contamination on first Qwen retry; #45874 retains rejection/publication evidence. They belong to existing Native Stack #45750. Do not recreate their fixes. Producer access to exact review context is a hypothesis requiring a failing scenario before adding a new read surface. | One original request is joined across rejection, producer consumption, changed artifact, fresh verification and delivery. Same model/source cohort; no extra operator instruction to repair it. |
| Interrupted effects | A fixed Git revision publication followed by its verification-artifact publication resumes by reading the destinations and finishing the remaining obligation. | Direct native execution_store is already wired; #41640's implementation PRs are merged. Existing task-2184 tracks effect-without-settled-result recovery. Async composition already has immutable source/run/node/successor ownership; inline composition still lacks a durable cursor. #45927/#45933 track recipient artifact readback, not the whole G2 workflow. | Existing G2 six-case crash/readback matrix: exact effect/receipt barriers, matching destination revision, no duplicate effect, preserved unknown/conflict outcomes, and final independent acceptance/delivery. |
| Tool and observation quality | The agent can use the actual result of a tool and choose the next action from current evidence. | #45853 retains terminal authority observations lost after later calls in a real Qwen cohort; #45781 repairs descriptors rejected by the actual composition validator. Both are in #45750. #35413's recovery-payload fix #40491 is already merged. | Compare the same task family/model/environment before and after each change. Record final acceptance and delivery, wrong-result interpretation, rework and human rescue; lookup/latency improvements alone are insufficient. |
| Cooperation and fault isolation | Independent work continues when another request's retained payload is invalid; shared mutations retain exact owner/revision authority. | Goal verification currently loads all original bodies before selecting its Goal/request. A foreign original-body failure can therefore block a healthy Goal. Existing metadata discovery and selected-record reload are sufficient; no second registry is needed. | Actual Goal host processing completes and publishes the healthy subject's proof while the damaged subject remains explicitly invalid and unchanged. Recovery must also work after restart without repeating an already retained judgment. |

[MAST](https://arxiv.org/html/2503.13657v3) supplies failure categories and intervention
examples, not a new runtime layer. [SWE-agent](https://arxiv.org/html/2405.15793v3)
supports testing interface changes with the same model, within coding tasks.
[Scaling Agent Systems v3](https://arxiv.org/html/2512.08296v3) shows that collaboration
effects depend on task structure. Its empirical thresholds are not runtime limits.
[Long-running application harnesses](https://www.anthropic.com/research/harness-design-long-running-apps)
motivate actionable acceptance feedback, with confounded compute/scope comparisons.
[Managed Agents](https://www.anthropic.com/research/managed-agents) motivates separating
durable session evidence from disposable execution context; it does not prove
exactly-once external effects. These findings select hypotheses; none establishes
an effect size for MASC.

## First feature: Goal original-body failure isolation

The first controlled request is healthy Goal B's verification while a retained
original body for independent Goal A is invalid. Baseline source tracing identifies
the coupling in `Goal_verifier_worker.read_all`, `select_frontier`, and
`Goal_verification_agent.process_pending_work`. An executable negative reproduction
must establish the failure before a runtime repair is called proven.

Use existing `Lane_addon_tool_request_owner.discover` metadata and the canonical
Goal subject key `[goal_id, request_id, attempt]` to select the subject before
loading bodies. Reuse the existing selected-record reload/identity comparison.
Keep all attempts for the selected subject so absent roots, orphan children,
authority changes and original digest mismatches remain rejected. Scope pending
processing and boot recovery to each discovered Goal; preserve paused/blocked and
already-proven Goals whose publication still needs recovery.

The guarantee covers a foreign subject's original **body/Goal payload** failure.
Unclassifiable generic metadata remains an explicit inventory failure because
the hashed storage filename cannot independently prove its owner. Global census
keeps its strict semantics. Do not silently skip unknown metadata, create another
authority index, migrate live state or call partial discovery complete.

Functional acceptance:

1. Retain A and B through actual Original/Worker/Goal store entrypoints; corrupt
   only A's original body. Baseline B processing cannot reach proof publication.
2. With the repair, B's actual verifier host records proof, publishes the terminal
   result and reaches `Awaiting_confirmation`; human confirmation is still required.
3. A retains explicit failure and the same bytes. No fallback overwrites its data.
4. After a restart, a retained judgment for B is committed/published without another
   model invocation even while A remains damaged.
5. B's own corrupt payload, missing root, orphan successor or identity change still
   blocks B. Unknown generic metadata remains an explicit global diagnostic.

## Stack and verification scope

| Layer | Deliverable | Evidence |
|---|---|---|
| 1 | This feature map and linked work records | Current source, REST stack/issue census, MASC readback |
| 2 | Production-path negative reproduction | Baseline identity, exact selected suite and observed failure |
| 3 | Scoped original reads and Goal host recovery | Focused source review; same functional scenario on the candidate |
| 4 | Results and operator-facing behavior contract | Original baseline/candidate receipts, remaining limits and next work |

External coding sessions do not build locally. Explicit minimal behavior checks
use the repository's existing targeted test workflow; source review and parser
checks are not executed-feature proof. Keep selection and artifact identities,
including unrelated compilation failures that prevent the scenario from running.
Do not watch or poll CI, deploy the candidate, or claim production readiness from
this one scenario. At work boundaries, inspect the actual completed evidence.

## Measurement and tracking

The denominator is the original assigned user request. Count externally accepted
and delivered results separately from false completion, rework, duplicate effects,
explicit refusal, user cancellation, unknown outcome and still-running work.
Required final human confirmation is distinct from unplanned human rescue. An
observation cutoff does not expire the underlying work. [Tau-bench](https://arxiv.org/html/2406.12045v1)
motivates external-state checks and repeated-trial reliability; an internal retry
is not a fresh independent trial.

G1's synthetic IDs were removed, but operation/attempt/artifact/verdict producer
joins remain #44317 work. The runtime Goal `goal-reliable-change-g1-20260909` is
currently dropped; this plan does not reopen it or claim its acceptance. G1–G5
remain design/acceptance references. The separate #45747 Goal campaign has different
G1–G4 labels; do not merge their case identities. Its Tasks2595–2598 are currently
cancelled, while their PR stack remains open. Existing active task-2661 is owned
by another coding session and is not part of this implementation.

Tracking at registration (re-read before claiming later work):

| Work | MASC Task | GitHub record | Delivery scope |
|---|---|---|---|
| Feature plan and first stack | task-2662 | [#45943](https://github.com/jeong-sik/masc/issues/45943) | Current work |
| Rejection/correction/delivery acceptance | task-2663 | [#45747](https://github.com/jeong-sik/masc/issues/45747), Stack #45750 | Follow-up; reuse active implementation |
| Two-stage interrupted effects | task-2184 | [#41640](https://github.com/jeong-sik/masc/issues/41640), [#45927](https://github.com/jeong-sik/masc/issues/45927) | Existing unclaimed work; whole G2 remains |
| Tool-observation completion comparison | task-2664 | [#45747](https://github.com/jeong-sik/masc/issues/45747), PRs #45853/#45781 | Follow-up acceptance |
| Actual G1 producer joins | task-2665 | [#44317](https://github.com/jeong-sik/masc/issues/44317) | Follow-up; no synthetic identities |
| Goal original-body isolation | task-2666 | [#45946](https://github.com/jeong-sik/masc/issues/45946) | First feature stack |

The follow-up Tasks are not implemented or completed by this first stack. They
preserve the full feature plan while the selected failure is repaired and proved.
