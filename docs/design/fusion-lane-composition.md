# Fusion package composition

Fusion can be represented as a composite Lane: a shared question and evidence
fan out to panel seats, converge at a judge, optionally pass through review,
and produce an advisory result. The [interactive composer](lane-addons-composer.html)
shows isolated panel/Judge packages as horizontal workers and vertical connections.
The existing host Fusion result path can also be inspected as a composite block.

## Implemented boundary

The new [fusion-results package](../../addons/fusion-results/README.md) runs as
an ordinary isolated Add-on projection worker. It consumes explicitly exported
Fusion detail snapshots through the existing snapshot_file adapter, preserving
run identity, status, failure, evidence state and the exact-run Board post.
It publishes `status` and `result` ports for generic downstream lane_output
composition. The existing image workflow discovers it without a new dispatcher.

This projection path changes result composition, not where its computation runs.
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
The MCP facade also carries verified Lane authority separately from the attributed
name; omitted authority is unauthenticated. Unreadable retained visibility is
omitted from inventory without discarding its evidence or exposing its rows.
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

Prepared Broadcast operations retain the same strict visibility and exact saved
caller identity. A verified retry authorizes that durable operation before looking
up the original source binding, so its committed receipt remains recoverable after
source removal. Unverified attribution and foreign callers cannot retrieve it.

## Composer

The standalone HTML supports adding, duplicating, renaming and removing blocks,
connecting compatible outputs, fan-in/fan-out, automatic topological layer layout,
undo and validated JSON import/export. The default example connects one shared
input to two isolated `fusion-compute` panels, a `fusion-compute` Judge and a
`fusion-report` worker. The computation workers publish the actual `result` port;
the editor uses `computation` as its compatible connection type.
The editor can also open a `fusion-report` output JSON or its successful MCP
`structuredContent` response. Received report bodies and input gaps are shown
as plain text. A report's run, analysis and producing installation can be
compared with declared inputs; a match describes the draft wiring only. Editing
or importing another draft recalculates that comparison. This viewer does not
verify evidence, query a server, install a worker or create sharing/read receipts.
An independently opened Evidence receipt exposes its owner, exact selected row
IDs and intended Keeper/Broadcast delivery state. The viewer associates it with
a report only when the row ID is selected and its native Lane name matches the
receipt's owner exactly. An unowned package row or another observation stays
unassociated. This compares file coordinates only; it does not verify payload
digests or turn delivery acceptance into Keeper reading or use.
The existing host Fusion example is one external block whose panel
roles and simple/refine structure can be inspected and edited internally.
Fusion's other host topologies are accepted by the result projector but are
not editable in this first UI.

The example output types `insights` and `computation` are design-level connection
type. It is not a new server schema or the package's actual `status/result`
port schema. Importing a graph does not install or run it.

The missing-source preview uses synthetic data only. It propagates source
references and missing inputs without claiming model execution, Board publication,
Broadcast delivery or Keeper reads. Explicit host Evidence sharing and the Fusion report package are implemented in
source. The editor’s automatic Broadcast connection remains a proposed flow;
its preview never sends a message or records an agent reading it.

## Validation and remaining work

The explicit Docker package qualifier executes a generated declaration plan
through separate panel, Judge and report containers. It compares baked source
bytes, image identity, declared resource limits and isolation flags, then checks
MCP responses and retained fixture request/outcome references in the report.
For independent panels, two fixture barriers hold model replies until every
panel has requested sampling. Docker inspection records all those containers
running before any reply is released. Their answers then converge through the
Judge and report. This proves package-level concurrent sampling without timing
or sleep guesses.
The fixture transport has a deadline that kills and reaps its attach process
if a package stops replying. This lets failed parallel qualification reach
owned-container cleanup; it does not set a product sampling timeout.
Only containers bearing its own run label are removed. It does not invoke the
native MASC factory, resolve real named ports, use the native scheduler, call a
provider, Broadcast or a Keeper. Images must already be built from the current
checked-in package Dockerfiles; it does not run automatically in CI.

```sh
python3 test/qualify_lane_composition_containers.py \
  --plan <generated-declarations.json> \
  --compute-image <proof-compute-image> --report-image <proof-report-image> \
  --output-dir <evidence-directory>
```

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
The isolated computation and explicit artifact-sharing source paths are described
below. Native/container execution and actual Keeper decision use still require
proof. Generic composite/subflow execution is not introduced by these packages.

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
as separate states. Report generation and isolated computation are implemented
in source; graph-driven automatic Broadcast execution remains follow-up work
under issue #40183.

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

The original preview HTML, composition, browser receipts and screenshots are
retained from historical integration commit
`125600b0e5909ac44b05e2f06da6bd09c9fe418e`. Their hashes remain linked by
`preview-checks.json`; they are not screenshots or browser execution of this
merged revision. The parent preview bundle is separately archived as described
in `docs/evidence/fusion-report-20260930/README.md`.

## Explicit report sharing

The host Evidence operation requires a caller-generated `request_id` for every
`broadcast=true` send. An unanswered send is retried with its original ID; a new
deliberate send uses a fresh ID even for the same selected rows. The TUI retains
unacknowledged IDs until a committed receipt and carries them across reopening
that evidence selection. The host retains the first published artifact and
reconciles the authoritative message by its exact derived workspace request ID,
so a retry can recover its receipt while the original fleet fanout is blocked.
This does not claim fleet delivery or reading has finished.

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

## Installation declaration preview

The editor's isolated template can generate four real TOML declarations: two
`fusion-compute` panels, a `fusion-compute` Judge and a `fusion-report` worker.
Enter shared run/analysis/question and server manifest paths in common settings.
Select each worker to enter installation identity, declared model route,
instructions and provider output limit. The source block requires both the
server file path and that retained JSON envelope's exact `source_id`.

The preview compiles compatible edges into same-run `snapshot_file` and
`lane_output` bindings with the producer's `result` port. Missing routes/paths,
duplicate input or installation identities, incompatible ports and cycles are
errors. The preview offers one download per declaration; it does not install,
build images, call a model or publish messages. Broadcast/agent blocks remain
manual delivery plans and generate no declarations or automatic sends.

Saved JSON uses version 2 and includes common settings and worker bindings.
Import and undo restore the same saved state used for TOML generation. A version
1 graph without this installation contract is rejected rather than combined
with stale settings. Other conceptual templates remain editable but are not
silently translated into unsupported packages.

`test/test_lane_composition_export.mjs` checks the actual HTML template,
serialized settings roundtrip and negative cases. Python parsed the generated
TOML and passed its exact bindings through four shipped package MCP subprocesses
with fixture host answers. Actual Chromium interactions additionally verify field edits, TOML download,
Undo, saved JSON import and a 390px layout. Source hashes, screenshots and results
are in [browser evidence](../evidence/lane-composer-browser-20260930/summary.json).
JSON-schema-engine, native host acquisition, Docker and live model verification
remain separate and unproven.

## Isolated computation and shared evidence

`fusion-compute` runs as an isolated package with `panel` or `judge` role. It
requests model access through its declared host sampling route; the worker has
no provider network or injected host credentials. The host persists the exact
model request before invocation, then retains the actual answer, failure or
uncertain outcome. A Judge consumes explicitly bound completed upstream ports.
Missing observations return waiting coverage without a model call. Its result
propagates ancestral source and model references so final `fusion-report`
artifacts include panel and Judge evidence.

The `source_changes` runtime compares completed input identities for automatic
producer refreshes. Acquisition time does not create a new Lane-port generation;
producer identity, output, mapping, status and coverage remain part of the input.
Explicit Observe always runs. Native source/composition scenarios force an
overlapping notification and check one call, explicit retry and a new generation.

The manual container qualification uses the real runtime and host factory, four
workers installed together, and synthetic loopback HTTP model replies. It checks
panel overlap, original request/outcome artifacts, container isolation, explicit
local-fixture Broadcast receipts and Keeper artifact bytes after detach. Native
execution is unverified; the previous probe CI failed during compilation because
its direct MCP protocol dependency was omitted. That dependency is repaired
locally. The operator has stopped CI; no fresh run or push is claimed here.
