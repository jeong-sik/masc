# Fusion result composition: first implementation

Fusion can be represented as a composite Lane: a shared question and evidence
fan out to panel seats, converge at a judge, optionally pass through review,
and produce an advisory result. The [interactive composer](lane-addons-composer.html)
shows that structure inside one editable block.

## Implemented boundary

The new [fusion-results package](../../addons/fusion-results/README.md) runs as
an ordinary isolated Add-on projection worker. It consumes explicitly exported
Fusion detail snapshots through the existing snapshot_file adapter, preserving
run identity, status, failure, evidence state and the exact-run Board post.
It publishes `status` and `result` ports for generic downstream lane_output
composition. The existing image workflow discovers it without a new dispatcher.

This changes result composition, not where model computation runs.
Fusion still owns panel/judge calls, durable async request identity, terminal
settlement, Board projection and continuation delivery in the host.
The package has no credentials or compute/action port.
The exporter reads an already-acquired API response; it neither fetches
the API nor updates a capture automatically.

## Composer

The standalone HTML supports adding, duplicating, renaming and removing blocks,
connecting compatible outputs, fan-in/fan-out, automatic topological layer layout,
undo and validated JSON import/export. Fusion is one external block whose panel
roles and simple/refine structure can be inspected and edited internally.
Fusion's other host topologies are accepted by the result projector but are
not editable in this first UI.

The example output type `insights` in the composer is a design-level connection
type. It is not a new server schema or the package's actual `status/result`
port schema. Importing a graph does not install or run it.

The missing-source preview uses synthetic data only. It propagates source
references and missing inputs without claiming model execution, Board publication,
Broadcast delivery or Keeper reads. Broadcast/report blocks remain proposed roles.

## Validation and remaining work

- Five stdio feature scenarios verify exact-run origin, immutable capture
  evidence, lifecycle and coverage, exporter identity and generic downstream
  composition. No OCaml local build was performed.
- The 80-case package suite had one sandbox-only localhost bind failure;
  the affected 14-case file passed when rerun with localhost access.
- Browser checks cover Fusion expansion, simple/refine selection, panel edits,
  independent copies, JSON round trips, graph editing, rejection of malformed
  connections, missing-input propagation and a 390px viewport.
  [Result](../evidence/lane-addons-ux-20260930/composer-checks.json) and
  [Fusion screenshot](../evidence/lane-addons-ux-20260930/composer-fusion.png).
- The required parallel review agent could not start because its access token
  refresh failed after an account change. The author performed direct review;
  this is not an independent review PASS.

Docker/host installation, current-head CI and production model/worker behavior
are separate evidence stages. None are claimed by the local stdio/browser checks.
The next runtime work is an explicit completion-to-snapshot acquisition bridge,
then the credential/runtime boundary for moving compute into isolation, and
durable Board/Broadcast/read integration. Generic composite/subflow execution
is not introduced by this slice.

Source authority: `lib/fusion_core/fusion_run_registry.ml`,
`lib/server/server_dashboard_fusion_run_projection.ml`,
`lib/fusion/fusion_orchestrator.mli`,
`lib/fusion/fusion_delivery_obligation.mli`,
and [generic output composition](../guides/lane-output-composition.md).
