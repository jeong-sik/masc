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
the API nor updates a file capture automatically.

The native `fusion_run` source additionally reads an exact run from the host
registry, retains its captured detail bytes and nudges matching observers when
Fusion publishes a new state. It does not require manual snapshot export.
Later independent Board card edits require explicit observation; the latest
completed output is a frozen capture, not a live mirror of arbitrary Board edits.

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
The native acquisition bridge is implemented with CI validation pending.
The next runtime work is the credential/runtime boundary for moving compute into isolation, and
durable Board/Broadcast/read integration. Generic composite/subflow execution
is not introduced by this slice.

Source authority: `lib/fusion_core/fusion_run_registry.ml`,
`lib/server/server_dashboard_fusion_run_projection.ml`,
`lib/fusion/fusion_orchestrator.mli`,
`lib/fusion/fusion_delivery_obligation.mli`,
and [generic output composition](../guides/lane-output-composition.md).
## Readable report output

The `fusion-report` package adds an executable projection after `fusion-results`:
native Fusion run → captured status/result → report → host Evidence delivery.
Its named `report` port contains the retained analysis body and exact input
lineage. The package keeps analysis completion, input completeness and delivery
as separate states. Report generation is implemented; model computation inside
an isolated Fusion package and graph-driven Broadcast execution remain follow-up
work under issue #40183.

## Composition verification boundary

The integration branch joins the report packages, native `fusion_run` source,
and declared-layer TUI. `test_lane_addon_composition` now includes a native
Fusion registry and exact-origin Board fixture feeding both shipped packages
over MCP stdio through real declaration reconciliation and source acquisition.
It asserts exact upstream identity, preserved report body, a deferred delivery
receipt, and reads the published evidence using `Keeper_artifact_read` after
both installations detach and the Lane evidence store is removed.

Container lifecycle and the delivery recipient are fixture callbacks. Artifact
reads exercise the real reader; they do not demonstrate a model understanding
or using the report. No Docker isolation, credential separation, Broadcast
publication, or production Keeper action is established by this scenario.
Its native execution remains pending targeted CI. The 14 Fusion Python MCP
package scenarios passed on the integration checkout.

## Explicit report sharing

The host Evidence operation accepts `broadcast=true` as an explicit alternative
to a single `keeper_name`. The TUI export menu offers workspace sharing after
the named Keeper choices and defaults to preservation only. Enter submits;
selection and cancellation do not publish a message.

The host publishes the selected immutable evidence as Keeper-readable artifacts
and sends the exact artifact marker through the existing workspace Broadcast
authority with `Fleet_conversation` audience. Report bodies remain inside the
retained artifacts, so untrusted text cannot introduce message mentions.
The receipt carries the committed message's request ID and sequence. A failed
publication preserves evidence; an unexpected recipient exception has an
unknown outcome and never triggers automatic resend. Non-cancellation failures
in the postcommit observation hook are logged without discarding the receipt.

The native composition scenario checks the actual isolated workspace message
row against its receipt and the same artifact sent to the selected Keeper.
A separate failure scenario checks rejected writes, caller requirements, invalid
destinations, retained evidence, and absence of automatic resend. The PTY
scenario checks selection, cancellation, explicit submission and visible receipt
using controlled HTTP data. All native/PTY execution remains pending current-head
CI; no live fleet Broadcast or model use is claimed.
