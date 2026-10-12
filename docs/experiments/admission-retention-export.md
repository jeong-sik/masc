# Source-rendered admission requests for retention experiments

The pending-write measurement proves separation from current Memory. This
fixture captures the real Librarian request needed to measure what knowledge
survives admission. It does not perform semantic judgment or call a provider.

Eight isolated cases cover repeated unchanged policy and independent release
rules at 1, 30 and 200 observations, plus a verified replacement and an unresolved
event. The actual write tool creates candidates. The actual admission runtime
passes its rendered prompt and output schema to an injected CLI runner. That
runner returns an all-deferred response solely to capture input without changing
current Memory. The fixture verifies real decoder completion and exact current
and pending bytes after receipt recovery.

Each `MEMORY_ADMISSION_EXPORT` JSON record includes the rendered user/system
prompts, output schema, complete candidate rows and facts, initial facts and
snapshot presence, source scenario, `candidate_receipts` and hashes. Each entry
is the receipt the queue issued for one candidate (queue generation, request
id, sequence and input SHA-256). The capture defers every candidate, so no
settle consumes them; they are not consumption evidence. Scenario hashes
exclude random IDs and timestamps; delivery hashes bind their actual values.
Initial observations use the current clock, avoiding an unrelated old
timestamp as a semantic cue.

Request only the exporter in CI:

```sh
gh workflow run test.yml --repo jeong-sik/masc \
  --ref experiment/admission-retention-20261009 \
  -f suite=test_keeper_memory_admission_export -f minimal=true
```

The targeted runner enables `ALCOTEST_VERBOSE=1`; a manual execution of the
already-built executable needs `-v` to expose successful captured stdout.
After completion, save the actual run/head and complete log. Recover exports:

```sh
python3 scripts/experiments/collect-admission-exports.py RUN.log exports/
```

Collection refuses missing/duplicate cohorts, malformed or truncated JSON,
hash mismatches and overwrites of different exports. Hashes for JSON objects
use original wire bytes so floating-point formatting is not normalized away.
Do not reconstruct missing request material by hand.

The scoped follow-up capture (`independent_200_followup`) is printed by the
replay suite (`suite=test_keeper_memory_admission_replay`) as
`MEMORY_ADMISSION_FOLLOWUP_EXPORT`, not by the export suite. Recover it from
that run's log with `--followup`:

```sh
python3 scripts/experiments/collect-admission-exports.py --followup REPLAY.log exports/
```

This mode applies the same checks, refuses a missing follow-up, and also checks
each present state-bundle file against its SHA-256 and that the export and its
scenario input name the same predecessor fixture and response hash.

For the next measurement, retain the untouched model response and replay it
through the real admission decoder and store with these candidate IDs and fact
payloads. A separate CLI model call is not the production Keeper exact lane.
Record model/runtime identity, request and response hashes, failures, deferrals,
actual retained facts and remaining candidates separately.

Evaluate applicability rather than sentence count. An exact scoped summary of
R-001 through R-200 can preserve knowledge; silently extending it to R-201 does
not. Repeated confirmations must not invent new policy, replacements must not
leave obsolete rules active, and unknown event identity must remain uncertain.
Synthetic "verified" evidence is an input assumption, not external provenance.


## Captured request evidence

Run [37813230133](https://github.com/jeong-sik/masc/actions/runs/37813230133)
at `b9ace853c1b654a2a30d74afd3fdd62a0008eaf5` succeeded for all eight cohorts.
The collector verified all eight exports and their hashes from the complete
`suite-runner-log` artifact (artifact ID11565922448). The ordinary `gh run view
--log` output contained only two complete exports and correctly failed the
collector's cohort-completeness check. Use the full artifact for large captures.

A separate Codex CLI0.161.0 call returned a policy-replacement response; three
other attempted cases ended with explicit usage-limit failures and produced no
response. The successful JSONL showed no tool-call item, but did not expose the
backend model identity. These calls do not establish production Keeper dispatch
or post-commit retention. The untouched replacement response is the next store
replay input; quota failures are not semantic judgments.
