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
The envelope must include `generated_at`; the run must declare
`run_kind=exact_output` and `skill_evidence={"state":"no_keeper_skills"}`.
These structural checks cannot authenticate that an endpoint produced the file.
Replace the placeholders with the actual full objects. The input payloads,
including the rendered prompt SHA, must match exactly. Each run and sample ID
may occur only once. Missing/unavailable payloads, missing timings and
contradictory skip/slot evidence are refused, never removed from a calculation.
The baseline must record disabled preflight, null preflight elapsed time, no
received-answer fields, explicit null domain rejection and entry to the generation
lane. Both arms require the complete recorded input shape: turn and Task/Goal context, Keeper instructions,
resolved prompt metadata and variables, and nonnegative message/fact counts.
Each actor must match its frozen `keeper_id`. Evaluated pairs require parsed
`continuity` to be null and parsed `working_context` to equal the producer's
empty projection: `{"sources":[],"previous":null,"unavailable":[]}`.
The projection does not expose `execution_basis` or a prior snapshot when sources
are empty, so this check cannot independently attest those runtime-only fields.
Identically truncated inputs are refused. Duplicate JSON keys are refused
before normalization, including within these two JSON variables; the manifest
digest describes canonical JSON, not the original file's whitespace or key order.
Keep all selected sample IDs in the manifest to avoid selection bias.

The CLI reads the same manifest incrementally, decoding one pair at a time with
Python's standard JSON decoder. It does not add a file-reference format or a
parser dependency. All selected samples remain in order, including failures.
Metadata may appear before or after the pairs. Duplicate keys and malformed or
trailing JSON are refused before any report is printed.

Canonical pair bytes are written to a private temporary file. After validation,
the reporter hashes its root members in sorted order, reading those bytes back
in chunks. This preserves the canonical manifest digest regardless of input key
order without keeping all decoded pairs. Input retention depends on the largest
pair or metadata value and decoder lookahead, not the sum of all pair inputs.
Prompt rendering still materializes one prompt. Sample/run identities and the
reported summaries remain in memory, so report-sized state still grows with the
sample count. This is pair-bounded input processing, not constant-memory parsing
of an arbitrarily large individual value.

The tradeoff is temporary disk space proportional to canonical manifest size,
plus serialization and disk I/O. Temporary-file failures refuse the report;
there is no input-size cap or silent sample omission. Preserve enough temporary
storage for the selected export set. A synthetic Linux CLI scaling measurement
uses 136,600,000 ASCII conversation bytes per arm; the raw evidence records
baseline and current RSS and verifies complete report equality for each batch.

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
`baseline_selected_slot`, `preflight_selected_slot` and
`preflight_domain_rejection` preserve the full-lane choices and fallback cause.
Different selected slots are permitted and visible; their timing delta may be
confounded by that routing difference.

Successful Memory runs require the flattened completion receipt: `exact_output`,
`before`, `after`, `absorption`, `claims_not_applied` and terminal `absorb_gate`
structures. A skipped absorb gate is valid. Failed and cancelled runs do not
require these success fields. The receipt checks do not rerun the native domain
validator, verify semantic claims or attest persistence from an external export.
Failed runs require their code and detail; other terminal statuses must omit
both fields. Goal contexts require exactly the fields emitted for their recorded
status, so stale fields from another variant are refused. `baseline_failure` and
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
