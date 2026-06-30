# Dashboard Interaction Judge Fusion Lifecycle

Owner issue: <https://github.com/jeong-sik/masc/issues/22656>

## Purpose

`/api/v1/dashboard/interaction-judge` is intentionally disabled until the
dashboard Interaction Judge is migrated onto the Fusion lifecycle. The disabled
response uses `next_action = "migrate_to_fusion_job_lifecycle"` and exposes this
document through `lifecycle_contract.doc_path`.

This contract prevents that next action from becoming a free-floating string.
The disabled route remains observable, but production execution must not resume
through the old dashboard polling loop.

## Target Lifecycle

The Interaction Judge migration target is a Fusion-backed job with these
boundaries:

- Entrypoint: the dashboard Interaction Judge route requests or observes a
  Fusion job owned by the `interaction-judge` lane. It must not run a bespoke
  dashboard LLM loop.
- Registry: in-progress and recent completed jobs use `Fusion_run_registry`.
  Dashboard read projection is `GET /api/v1/dashboard/fusion-runs`.
- Status event: lifecycle deltas use the existing `fusion_run_status` SSE event
  emitted by `Fusion_sink.broadcast_run_status`.
- Owner lane: records use `owner_lane_id = "interaction-judge"` so dashboard
  projection can distinguish Interaction Judge jobs from ordinary keeper Fusion
  calls.
- Prompt template: `config/prompts/dashboard_interaction_judge.md` remains
  intentionally registered while the route is disabled. It should be reused by
  the Fusion job unless a replacement prompt is introduced in the same PR that
  removes it.

## Request Contract

A future live Interaction Judge request must be represented as Fusion input,
not as dashboard-local loop state. The minimum request shape is:

```json
{
  "caller": "dashboard_interaction_judge",
  "owner_lane_id": "interaction-judge",
  "prompt_template_id": "dashboard_interaction_judge",
  "facts_json": {},
  "requested_at": 0.0
}
```

`facts_json` is the same keeper-interaction evidence the disabled prototype used
to build the prompt. The Fusion job may add preset/model fields, but those fields
must come from Fusion configuration, not from a dashboard-only hardcoded model.

## Response Contract

While disabled, the route returns:

```json
{
  "enabled": false,
  "judge_online": false,
  "refreshing": false,
  "status": "disabled",
  "next_action": "migrate_to_fusion_job_lifecycle",
  "lifecycle_contract": {
    "id": "dashboard_interaction_judge_fusion_lifecycle",
    "issue_url": "https://github.com/jeong-sik/masc/issues/22656",
    "doc_path": "docs/design/dashboard-interaction-judge-fusion-lifecycle.md",
    "fusion_runs_route": "/api/v1/dashboard/fusion-runs",
    "fusion_run_status_event": "fusion_run_status"
  },
  "data": {
    "stigmergy": {},
    "interactions": []
  }
}
```

The eventual live route must preserve the existing `data.stigmergy` and
`data.interactions` projection for `dashboard/src/components/world-visualizer.ts`.
It may add fields, but it must not remove those fields without changing the
consumer in the same PR.

## Status Labels

The disabled route currently publishes:

- `disabled`: no production Interaction Judge execution path is active.

The Fusion lifecycle target reuses the `Fusion_run_registry.status_label`
vocabulary:

- `running`: a Fusion job is executing.
- `completed`: the Fusion judge/sink completed successfully.
- `failed`: the Fusion job was denied, aborted, or completed with a failed sink
  outcome.

No `queued` label is defined until a real admission queue exists. Do not add a
dashboard-only queued state.

## Timeout And Budget Policy

Interaction Judge execution inherits Fusion budget and timeout policy. It must
not add a dashboard-only infinite retry loop or a dashboard-only model timeout.

- Budget denial maps to a failed Fusion run with an operator-visible reason.
- Timeout behavior belongs to Fusion/OAS bridge policy and must be surfaced in
  the Fusion run record or completion evidence.
- The dashboard route may poll or subscribe to registry state, but it must not
  own cancellation semantics.

## Dashboard Projection

The dashboard projection is split:

- World Visualizer keeps using `/api/v1/dashboard/interaction-judge` for the
  current interaction matrix and disabled state.
- Fusion surface and registry panels use `/api/v1/dashboard/fusion-runs` plus
  `fusion_run_status` SSE events for job lifecycle visibility.
- When the Interaction Judge becomes live, the route should derive its current
  state from the Fusion registry and the latest completed Interaction Judge job,
  not from an independent loop-local cache.

## Implementation Tasks

Before flipping `enabled` to true:

1. Add the Fusion job entrypoint for `caller = "dashboard_interaction_judge"`.
2. Register the job in `Fusion_run_registry` with owner lane
   `interaction-judge`.
3. Emit `fusion_run_status` for start and completion.
4. Project the latest completed job into the current `data.stigmergy` and
   `data.interactions` response shape.
5. Add tests for disabled, running, completed, failed, and budget-denied states.
