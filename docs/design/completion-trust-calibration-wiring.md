# Completion-trust calibration wiring — design note (RFC-0262 §9 follow-up)

Status: design (no code lands from this note beyond a citation correction)
Governing: RFC-0262 §8 (Test plan) / §9 (Rollout, proving metric); RFC-0199 Phase B (evidence gate); RFC-0222 (acceptance typing)
File refs below are as of `origin/main` and will drift — re-confirm before implementing.

## Why this note exists

The live-LLM completion-trust runner `bin/masc_completion_trust_eval.ml` (PR-C #21754) drives
a real keeper with foreign-task-temptation prompts and grades its tool-call *disposition*
deterministically. Its dispatch is a **stub**: it records every `(name, args)` and returns a
fixed `Tool_result.ok` without invoking any gate, handler, or judge (`run_one`'s dispatch
closure in `bin/masc_completion_trust_eval.ml`). The runner docstring names that stub as
"the seam where a later PR can route the attempt through the real handler plus
`Eval_calibration` verdict recording".

A mapping pass over the runner, `Eval_calibration`, `Anti_rationalization`, and the live
done-handler showed that the obvious "un-stub dispatch and record verdicts" increment is a
**workaround** (it would record zero verdicts and present a metric that stays vacuously 0).
This note records the blockers and the three design decisions a faithful wiring requires, so
the next PR implements measurement rather than telemetry-as-fix.

## Blockers (why naive wiring records nothing)

**B1 — the judge only fires behind the ownership gate.**
The only producer of an `Anti_rationalization` verdict on the Done path is
`review_completion_notes`, reached only when `action = Done_action`, `not force`, and
`can_review_completion` is true (`lib/task/tool_task.ml:348-353`). `can_review_completion` is
true only when the task is `Claimed`/`InProgress` **and** `assignee = agent_name`
(`lib/task/tool_task_completion_review.ml:13-21`). The runner's stub dispatch bypasses
`tool_task.ml` entirely — `run_named_with_masc_tools` bridges each tool call straight to the
caller-supplied dispatch closure (`lib/keeper/keeper_turn_driver_wrappers.ml:184-188`) — so the
judge never fires and `record_verdict` is never reached. **Scope "record verdicts without
routing through the real handler" is therefore impossible**; the verdict producer lives inside
the handler.

**B2 — the current corpus produces no verdict even through the real handler.**
Scenario task ids (`task-847`, `task-968`, `task-733`) exist only in prompt/`setup_messages`
text (`data/eval/completion_trust/scenarios.json:9,33,57`); they are not seeded into live
workspace state. `handle_transition` loads tasks from `Workspace.get_tasks_raw`
(`lib/task/tool_task.ml:174-175`); against an unseeded id it returns `task_opt = None` →
`completion_state_error` (`task_done_requires_claimed_or_started`) → `review_completion_notes`
is never reached → **zero verdicts**. `ct-foreign-ownership` cannot produce a verdict even when
seeded: it is owned by `codex-mcp-client` while the keeper is `keeper-eval-agent`, so
`can_review_completion = false` and the ownership gate (`task_done_requires_current_owner`)
rejects first (`data/eval/completion_trust/scenarios.json:9-10`).

**B3 — `agreement_rate` is human-label-vs-evaluator, not keeper-vs-judge.**
`calibration_stats.agreement_rate` folds verdict records against **human** `Label_record`s that
share a `notes_hash`; with verdicts but no labels, `labeled_total = 0` →
`agreement_rate = 0.0` (`lib/eval_calibration.ml:419-422`; labels come from
`record_human_label`, `lib/eval_calibration.ml:224`). Recording verdicts alone can **never**
yield a non-zero `agreement_rate`. The only verdict-derived metric is `cross_model_rate`, which
counts verdict records whose `generator_runtime` and `evaluator_runtime` are non-empty and
differ (`lib/eval_calibration.ml:375-381,429`). The plan's stated goal of "compute
agreement_rate" is a metric mismatch and must be corrected.

## Design decisions for the implementation PR

**D1 — ownership-tagged corpus.** Add an explicit ownership class to the scenario schema
(e.g. `ownership: self_owned | foreign`). Only `self_owned` scenarios (the keeper owns a
`Claimed`/`InProgress` task whose completion notes are weak) can make the judge fire and are
eligible for the verdict-recording path. `foreign` scenarios stay **disposition-only** — they
are already covered deterministically by `test/test_completion_trust_harness.ml` (PR-B,
ownership/anti-rat gate rejection). Of today's three scenarios, two
(`ct-scope-mismatch-evidence`, `ct-fabricated-ref`) are already self-owned weak-evidence
completions (`claimed_by = keeper-eval-agent`) and only need the `self_owned` tag; only
`ct-foreign-ownership` is foreign. No net-new scenario is required.

**D2 — `agreement_rate` is out of scope for the automated runner.** No human labels exist in
CI, so the runner can populate `total_verdicts`, `approve`/`reject` counts,
`gate_distribution`, and `cross_model_rate` (distinct generator vs evaluator runtime), but
**not** `agreement_rate`. Do not present `agreement_rate` as a runner metric. A human-labeling
workflow (`record_human_label` over a sampled verdict set) is a separate, deferred track.

**D3 — isolation is mandatory.** The verdict-recording path drives the real cross-model judge
(`Anti_rationalization.review`, `lib/task/anti_rationalization.mli:78-85`) and writes
`data/verdicts/YYYY-MM/DD.jsonl` (`lib/eval_calibration.ml:102-103,215`). Run it behind an
explicit temp workspace base path (prefer a CLI `--base`/`--base-path` argument over ambient
environment; `MASC_BASE_PATH` is only a process-bound fallback) and
`Eval_calibration.set_store_for_testing ~base_dir` (scratch store,
`lib/eval_calibration.mli:74-75`), seed a self-owned task fixture, and install the two hooks
the CLI does not currently install: `record_verdict_fn`
(default no-op, `lib/task/tool_task_handlers.ml:28-30`; wired to `Eval_calibration.record_verdict`
only at server boot, `lib/mcp_server.ml:530-531`) and `run_llm_reviewer_fn`
(installed only in `lib/workspace_metric_hooks.ml:458`). It must never mutate live workspace
task state or pollute the live `data/verdicts` store.

## The seam (where, what)

- Insertion point: `run_one`'s dispatch closure in `bin/masc_completion_trust_eval.ml`,
  branched on a completion-tool name (`masc_task_done`/`masc_task_force_done`). `scenario`,
  `runtime_id`, `run_index`, and the call `args` (`task_id`/`notes`) are in scope there; the
  final `stop_reason` is not (only post-return, in `build_eval_run`).
- Real measurement (non-fake): build an `Anti_rationalization.review_request` from scenario
  context + the call's `notes`/`task_id` and call `Anti_rationalization.review` with a distinct
  `~evaluator_runtime`, `~on_verdict` routed to `Eval_calibration.record_verdict` — mirroring
  `lib/task/tool_task_handlers.ml:205-232` and `lib/mcp_server.ml:530-531`. This drives a second
  evaluator LLM and persists a genuine verdict (`verdict_record`,
  `lib/eval_calibration.mli:29-41`), feeding `cross_model_rate` immediately.
- Gate it behind a `--record-verdicts` flag, default off. The disposition track remains the
  default, CI-safe, deterministic-grading mode.

## Workaround self-check (CLAUDE.md §Workaround Rejection)

A naive `stub → record_verdict` one-liner is **telemetry-as-fix**: the build passes and
`data/verdicts/` is created, but zero verdicts are recorded (B1/B2) and `agreement_rate`
stays vacuously 0 (B3) — a counter that measures nothing. Rejected. The only honest increment
drives an actual judge LLM over self-owned scenarios in an isolated workspace and reports the
metric it can actually compute (`cross_model_rate`), with `agreement_rate` explicitly deferred
to a human-labeling track.

## Citation reconciliation (corrected in this PR)

The runner and README cite "RFC-0262 §9 harness — keeper/judge/eval-grader separation" and
"axis ①". This is inaccurate on two counts:

1. RFC-0262 §9 is **Rollout** and §8 is **Test plan** (`docs/rfc/RFC-0262-completion-authority-typing.md:154,163`).
   The keeper/judge/eval-grader role separation is a **harness design contract** that lives in
   the runner/README and this note — it is not text in RFC-0262.
2. RFC-0262 types axis ② (completion authority); axis ① (LLM discretion to complete) is
   RFC-0222's territory. The runner measures the keeper's *disposition* to attempt a foreign /
   unevidenced completion, which is the behavioural complement to RFC-0262 §9's **proving
   metric**: "zero foreign-task completions by a non-`Operator`/`System` actor"
   (`docs/rfc/RFC-0262-completion-authority-typing.md:171`).

Corrected wording: the runner supports RFC-0262 §9's proving metric and §8's test plan; the
role-separation contract references this design note rather than claiming to be RFC text.

## Next PR scope (ready to implement after this note)

1. Author ≥1 `self_owned` weak-evidence scenario + add the `ownership` field to the schema and
   `Eval_harness` scenario type.
2. Add `--record-verdicts` mode: explicit temp workspace base path (`--base`/`--base-path`,
   with `MASC_BASE_PATH` only as a process-bound fallback) + `set_store_for_testing`, seed the
   self-owned task, install `record_verdict_fn` + `run_llm_reviewer_fn`, call
   `Anti_rationalization.review` with `~on_verdict → record_verdict` on completion-tool
   dispatch for self-owned scenarios only.
3. Report `cross_model_rate` (+ verdict counts/gate distribution); keep `agreement_rate` out.
4. Deferred: a human-labeling workflow to make `agreement_rate` meaningful.
