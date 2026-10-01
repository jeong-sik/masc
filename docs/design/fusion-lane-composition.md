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

## Native source ownership

Native `fusion_run` captures are visible to the authoritative registry Keeper
and to the operator. HTTP access uses verified operator or agent credentials;
local actor attribution and player credentials cannot grant private source access.
Unknown and foreign run identities receive the same acquisition denial.

Every retained binding records a strict read visibility: shared, operator, or one
exact Keeper. Missing or unknown visibility fails closed. Inspect, Slice, evidence,
actions, lifecycle operations and subscription reads/acknowledgments apply that
policy after detach or restart as well as while a worker is live. Ordinary sources
remain shared. Configured native Fusion sources preserve their registry owner even
when the operator performs reconciliation. Derived `lane_output` consumers inherit
all upstream restrictions; mixed Keeper owners require operator access.

A consumer's retained visibility stays fixed for its incarnation. If an upstream
replacement becomes more private, acquisition refuses the new bytes until the
consumer is reattached with compatible visibility. Existing shared captures remain
readable under their original policy. Configuration inventory and declaration
editing apply source ownership before returning sensitive entries or current bytes.
Authenticated Keeper saves also retain document ownership separately from the
referenced run. Initial admission records the exact prior/proposed source digests
before writing; only a durable matching write establishes stable repair authority.
The owner can then read and repair malformed TOML or replace a run that has left
the registry. Proposed bindings still require current source authorization.
Ownership remains attached to the canonical workspace and document path; submitted
TOML cannot transfer it. Reconciliation also records the verified Keeper owner of
operator-created private declarations; exact-revision retained visibility can
establish that owner after its Fusion run leaves the registry. Corrupt ownership
records require operator repair.

The native regression fixtures cover direct and historical access, unverified
attribution, private graph propagation, subscription cursor preservation and an
upstream shared-to-private replacement. These are pending native execution; this
change does not claim current-head CI or production validation.

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

The report port includes a shared input-context row and the individual reports
that reference it. That context retains the whole input coverage, exact producer
coordinates, compact upstream row references and the immutable host output
digest. Full source rows remain readable through that digest. Each analysis body
appears once; metadata is not multiplied by the number of reported runs. MCP
structuredContent carries these rows, while text content summarizes the result.
The final serialized reply must fit the package manifest's resource envelope;
an oversized reply is refused without truncating analysis or accepting a report.

Regenerate the fixture composition and preview with
`python3 scripts/fusion-report-preview.py`, then regenerate browser screenshots
and receipts with `python3 scripts/fusion-report-preview-browser.py` (requires
Playwright and its Chromium browser). Browser receipts in
`docs/evidence/fusion-report-20260930/preview-checks.json` identify the exact HTML
and composition hashes, delivery label, lineage interaction and screenshots.

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
Run the native composition test and the Python MCP package suites against the
composed head; historical receipts do not establish execution of a later merge.
