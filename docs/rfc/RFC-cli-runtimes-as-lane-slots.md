---
rfc: "cli-runtimes-as-lane-slots"
title: "CLI runtimes as lane slots"
status: Draft
created: 2026-08-29
updated: 2026-08-29
author: vincent
supersedes: []
superseded_by: null
related: ["claude-setting-sources-opt-in"]
---

# CLI runtimes as lane slots

## 1. Problem

The five registry lanes admit only HTTP catalog targets: an exact-output slot
is an `Exact_output.admitted_target`, which exists exactly for providers with
a `base_url` and a serializable request body. The three official-client CLI
runtimes (claude_code, codex_app_server, antigravity — the operator's route
to Gemini) cannot serve a lane at all, even though they are often the
highest-quality models available to the deployment. The operator asked for
exactly this on 2026-08-29 ("exact lane 에도 CLI 되게 해야지", concretely:
Gemini 3.7 via antigravity as a judge/librarian slot).

## 2. What the codebase already proves

Two existing surfaces show both halves of the answer working separately:

- **verifier_exact never uses `Exact_output`.** It resolves slot id strings
  (`Runtime.verifier_exact_lane_slot_ids`), hand-rolls the failover walk, and
  takes its verdict through a **tool call** (`report_review_verdict`) instead
  of schema-constrained text (`anti_rationalization.ml`). A lane whose output
  channel is a tool call does not need a request-body serializer at all.
- **Fusion already drives CLI one-shots.** `fusion_official_client.ml` builds
  claude/codex/antigravity configs for a single question-and-answer turn,
  with the session store, admission, and cancellation semantics already
  settled by the keeper lanes.

So the missing piece is not CLI execution and not tool-call output — it is
only the composition of the two under a lane's slot-walk discipline.

## 3. Decision (proposed)

Add a masc-side lane runner for CLI slots, and keep `Exact_output` HTTP-pure:

- A lane slot list may name a **runtime id** (e.g.
  `antigravity_subscription.gemini-3-7-flash-high`) alongside exact-output
  target refs. Admission: the runtime must resolve
  (`Runtime.get_runtime_by_id`), be an official-client execution, and the
  lane's declaration must opt in per slot — no implicit widening.
- A CLI slot executes as a **fusion-style one-shot** with exactly one dynamic
  tool: `lane_output`, whose input schema IS the lane's domain schema. The
  turn's acceptance is "called `lane_output` exactly once" — the verifier
  lane's proven contract, which makes provider-side JSON discipline
  irrelevant (the CLI's own tool-call machinery enforces the shape).
- Failure classes map onto the lane's existing vocabulary: no tool call →
  domain-invalid (advance); CLI admission/spawn failure → setup failure;
  cancellation completes the observation row (#31482 discipline).
- The run registers in `Exact_lane_run_registry` like any other slot, with
  `selected_slot` = the runtime id. The registry's input exactness contract
  is honoured by capturing the rendered prompt and the tool schema, not a
  request body (there is none).

## 4. Deliberately out of scope

- Extending `Exact_output.admitted_target` with a CLI execution adapter.
  Request-body projection, `within_limit`, receipt sha256 of the serialized
  body, and catalog generation fingerprints all quantify over an HTTP wire;
  a CLI has none of these. Grafting one in would weaken the exactness
  meaning of every existing receipt.
- Per-turn interactive tools inside a lane run. A lane one-shot gets exactly
  the `lane_output` tool; a slot that needs retrieval belongs to a keeper,
  not a lane.

## 5. Costs and risks

- A CLI one-shot pays session admission and process spawn per run —
  hundreds of ms to seconds of overhead before the model runs, against
  1–5 s HTTP lane runs measured on 2026-08-29. CLI slots therefore fit
  judge-quality positions (verifier, hitl) better than high-frequency ones
  (librarian at every third turn per keeper).
- Subscription quotas (kimi 5h, provider windows) apply to lane traffic too;
  lane declarations should keep an HTTP fallback slot after any CLI slot.
- The wall-clock ceiling knob (#31368) applies to keeper turns; the lane
  runner needs its own per-run bound from the start (the lane audit found no
  lane-level timeout anywhere — W-series).

## 6. Verification sketch

- Unit: slot admission (unknown runtime id → typed setup error, not a
  silent drop; non-official-client runtime refused).
- Fixture: a fake CLI that answers the `lane_output` tool once → succeeded;
  answers text without the tool → domain-invalid and the walk advances to
  the next slot; killed mid-run → cancelled row persists.
- Live canary: one lane (hitl_auto_judge) with a trailing CLI slot behind
  the current HTTP slots, measured for a day before widening.
