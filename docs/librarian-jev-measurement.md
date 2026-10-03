# Comparing Librarian preflight runs

`scripts/librarian/compare-preflight.py` reads frozen run-detail exports. It
does not start a model call, activate runtime configuration, modify Memory or
prove the Goal. It reports recorded routing and the median of each pair's
preflight duration minus baseline duration. Failures and cancellations stay in
the population; a fast failed run must not be reported as successful work.

For each frozen source input, run the baseline with `librarian_preflight=false`
and the candidate with it enabled in an isolated test workspace. Reset the same
input Memory/context between arms and alternate arm order across repeated
samples. Keep configuration equal except for that flag. Capture the binary
identity, configuration without credentials, measurement conditions, API
exports, actual provider dispatch traces and independent semantic judgments as
separate evidence. Request focused native execution according to the repository
execution protocol. Do not replay against production Memory to collect a test.

The server exports each retained detail at
`GET /api/v1/dashboard/exact-lane-runs/<run_id>`. A manifest contains:

```json
{
  "source_head": "<40 lowercase hex characters>",
  "config_sha256": "<64 lowercase hex characters of shared config excluding the toggle>",
  "environment": "<conditions and captured binary evidence reference>",
  "evidence_kind": "fixture",
  "pairs": [
    {
      "sample_id": "one",
      "baseline": "<replace this value with the complete baseline response object>",
      "preflight": "<replace this value with the complete preflight response object>"
    }
  ]
}
```

Each response has the shape `{"generated_at": "...", "run": {...}}`. Assign
that entire object directly to the arm; do not wrap it in another `run` object.
Replace the placeholders with the actual full objects. The input payloads,
including the rendered prompt SHA, must match exactly. Each run and sample ID
may occur only once. Missing/unavailable payloads, missing timings and
contradictory skip/slot evidence are refused, never removed from a calculation.
The baseline must record disabled preflight, null preflight elapsed time, no
received-answer fields and entry to the generation lane. Both arms require the
complete recorded input shape: turn and Task/Goal context, Keeper instructions,
resolved prompt metadata and variables, and nonnegative message/fact counts.
Identically truncated inputs are refused. Duplicate JSON keys are refused
before normalization; the manifest digest describes canonical JSON, not the
original file's whitespace or key order.
Keep all selected sample IDs in the manifest to avoid selection bias.

```sh
python3 scripts/librarian/compare-preflight.py frozen-manifest.json > report.json
python3 test/test_librarian_preflight_report.py -v
```

`declared_*` fields repeat manifest labels; the reporter does not verify a
binary's source identity or the operator's environment declaration. The
manifest digest and pair-level input hashes bind the report to its supplied
exports without copying prompts into the report. Preserve both manifest and
report privately: raw exports can contain Keeper instructions and conversation,
and preflight failure evidence can include provider response bodies.

Each pair retains `preflight_observation`, including its own `status`, decision
or failure, independently of `preflight_status` (the whole Librarian run).
A successful fallback can therefore still show a failed JEV evaluation.
Failed runs require their code and detail; `baseline_failure` and
`preflight_failure` retain these diagnostics separately, with null for other
terminal statuses.

Both recorded intervals currently use `Eio.Time.now` on `Eio.Stdenv.clock`,
the real-time clock, rather than `Eio.Time.Mono`. Clock corrections can make
the inner interval exceed the enclosing interval. The reporter preserves both
values and does not invent a duration cap or silently replace either reading.
Use separately captured monotonic-clock evidence when comparing performance
across clock corrections.
Received judgments require complete typed provenance and a valid probability
distribution; incomplete exports are rejected for every evidence kind.

`recorded_generation_skips` counts accepted skip records. It is not an actual
provider-request counter. `full_lane` may refuse admission before dispatch or
fail over through several providers. Actual request count, semantic quality
and installed TUI agreement remain `not_measured` in this report. Compare
constraints, preferences, corrections and unresolved obligations with the
frozen expected outcome independently, including false no-change decisions.
The report always leaves `goal_completion=not_established`.

Workstream: task-2023, goal-1790911534058-d6e92111, issue #40755. Synthetic
CLI tests establish report integrity only; their durations are not performance
measurements of Librarian or JEV.
