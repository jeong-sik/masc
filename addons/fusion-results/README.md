# Fusion results as a composable Lane output

This package projects a **captured Fusion detail response** into named
`status` and `result` outputs. Downstream Add-ons can consume those outputs
with the existing `lane_output` binding. The worker runs inside the existing
Add-on Docker lifecycle; it has no model credentials, network acquisition,
Fusion execution, Board publishing or Broadcast action.

Fusion computation and durable request/projection/delivery ownership remain in
the existing host. This is the first **result connection**, not migration of
the panel/judge computation into a package.

## Capture and install

### Native host binding

On hosts containing the native Fusion source, use
[fusion-live-results.toml](../../docs/examples/lane-addons/fusion-live-results.toml).
The source names the exact canonical Fusion run ID and reads its process-wide
registry plus exact-origin Board evidence. No HTTP call or manually copied
snapshot is needed. A registered Fusion state change nudges only matching
installed sources; attach/explicit observe also captures the current run.

Every observation is a frozen snapshot retained by the host. Source completeness
describes that one capture, not all historical Fusion stages. Missing runs are
unavailable coverage with no fabricated rows.

This subscription follows Fusion status publications, not later arbitrary edits
or deletion of the Board card. Such mutations require explicit observe to
capture a changed card; old snapshot evidence remains readable. A last completed
output means last captured, not a continuously synchronized copy of the Board.

### Explicit file capture

1. Explicitly acquire one authorized
   `GET /api/v1/dashboard/fusion-runs/<exact-run-id>` response and save the JSON.
   Use the configured server address and its normal authentication.
   The exporter below performs no network access.
2. Wrap that detail in the existing snapshot_file envelope:

   ```sh
   python3 addons/fusion-results/export_snapshot.py fusion-detail.json fusion-snapshot.json --source-id fusion
   ```

   The snapshot event ID/cursor hashes the complete canonical response;
   source incarnation remains the exact Fusion run ID. The exporter refuses
   overwriting an existing file. Choose a new path for a later capture and
   explicitly update the declaration.
3. Build/load the manifest's image through the existing package image workflow.
   Install the [example declaration](../../docs/examples/lane-addons/fusion-results.toml),
   resolving manifest and snapshot paths relative to the copied declaration.
   Host snapshot acquisition retains the file bytes and prepends their digest
   to each observation. A raw API response alone is not a snapshot_file envelope.
4. Observe the installed worker. Consume named `result` or `status` outputs
   within the same run. The [statistics declaration](../../docs/examples/lane-addons/fusion-result-statistics.toml)
   demonstrates the existing generic composition path.

## Evidence and failure semantics

- The named `result` port includes both status and result lanes so its related
  status row and recorded failure cause stay available to downstream consumers.
- Status rows preserve exact run ID, keeper, preset, topology, run lifecycle,
  failure code, timestamps and the API's evidence state. Status, stage and progress
  must agree with the host wire contract, including exact nonnegative panel counts.
- The source incarnation must equal the detail's run ID. Pending evidence
  requires a running run; absent evidence requires a terminal run.
- Result rows exist only when a captured Board post has `origin.source=fusion`
  and `origin.fusion_run_id` equals the exact captured run, the immutable
  `fusion_producer` equals its Keeper, and the recorded body is a string.
  The supplied Board body is retained as data, never instructions.
- Decision text from the run registry is explicitly a **decision preview**.
  It is not the complete typed judge decision or proof of execution.
- Running, terminal-without-evidence, failed-without-evidence, empty and
  mixed-kind inputs have incomplete coverage. Failed runs with exact recorded
  evidence can be completely observed while still carrying a failed run status.
  Observation completeness is not deliberation success.
- Unknown states/topology, inconsistent timestamps, malformed failure and
  mismatched Board origin reject the observation. Output actors are null;
  a snapshot's exporter is not substituted for a model or judge.
- These are frozen captures. No automatic Fusion completion notification,
  refresh of an API response, Keeper read, or delivery success is inferred.

The MCP text content is a compact summary; complete rows and Board body appear
once in `structuredContent`. The actual UTF-8 JSON-RPC response, including its
newline, must fit the existing manifest reply envelope. An oversized response
returns an explicit bounded error with no accepted output; source bytes are never
trimmed. The container includes the same manifest used for this check.

## Validation boundary

Real stdio worker scenarios exercise status/result separation, exact origin,
partial input, failure and generic downstream composition.
They do not establish Docker isolation, host installation, model execution,
current-head PR CI success or production deployment. The CI image workflow
discovers this package through lane.toml + Dockerfile.

Native Fusion bindings attached by a Keeper are private to that authenticated
Keeper. Inspect, retained slices, evidence export and instance operations keep
that owner boundary after restart. Configured native Fusion sources retain the authoritative registry Keeper as
their read owner, including when the operator performs reconciliation. A verified
Keeper may save its own run declaration or use `masc_lane_attach`; neither path
promotes the source into shared read authority. Downstream output consumers inherit
that visibility, and HTTP local attribution alone cannot grant private access.
