# Original Ask follow-up artifact comparison

The offline reader consumes client Log.Ring JSONL from the opening local
`<base-path>/.masc/logs/tui/session-<pid>-*/`. Copy the relevant complete retained
files into a comparison packet directory before hashing. This command does not
collect data, run a TUI/provider, deploy a binary or establish execution identity:

```sh
python3 scripts/harness/perf/tui_ask_followup_report.py packet/packet.json \
  --json packet/report.json --markdown packet/report.md
```

Both outputs must be new files. Existing files, including input artifacts, are
not overwritten. This source unit has not run this command or its resource case.

## Packet contract

The packet has `schema_version: 1` and a `cases` list. Each case has a unique
nonempty `id` and `before`/`after` objects. Each object contains exactly:

| Field | Value |
|---|---|
| `instances` | Nonempty list of original `origin.tui_instance_id` strings |
| `attempts` | Independent roster of original attempt objects described below |
| `conditions` | Five declared SHA256 condition values, or null when unknown |
| `source_commit` | Declared 40-character lowercase commit, or null |
| `binary` | Optional artifact object, or null; verified bytes are not execution proof |
| `logs` | List of JSONL artifact objects |

An artifact object has `path` (canonical relative POSIX path below the packet)
and `sha256` (64 lowercase hex characters). Files must be regular, stable while
read, hash-matched and reached without symlinks. The reader does not open sockets
or execute their contents. Each condition object has all five fields:
`fixture_sha256`, `workspace_snapshot_sha256`, `action_sha256`,
`server_binary_sha256`, `terminal_sha256`. Values are declarations about the
comparison inputs, not inferred from reported version strings. Unknown nulls
never count as matching conditions, including when both sides are unknown.

Each declared attempt has `instance_id`, `request`, and
`read_admission_started_ns`. Request and clock are JSON integers. The clock is
an original nonnegative Int64 nanosecond value, not the string clock schema of
the separate startup report. Preserve the independent full admitted-attempt
roster; selecting successful reads from the log alone cannot recover filtered or
unlogged attempts. All observed reads for the selected instances are unioned
with this roster; undeclared observed attempts and reused instances across arms
or cases are reported as evidence errors, not silently excluded.

## Output and interpretation

JSON retains each attempt's immutable original provenance, raw structured facts,
artifact path/digest/line/row identity, missing stages, producer and UI outcomes,
exact integer intervals, per-outcome denominators and evidence errors. It also
retains packet/analyzer hashes and storage-initialization spans. Source snapshots
are opaque retained evidence; this reader does not interpret them as Task work.

Markdown compares read outcomes and mean milliseconds with `observed/all` beside
each duration. Missing intervals stay unobserved. JSON keeps exact sum, count,
min/max and rational mean deltas; displayed means/deltas are rounded. Deltas
require complete equal declared conditions and error-free, disjoint cohorts.
They describe observed subsets, not an overall speedup or readiness verdict.
Every report explicitly keeps execution verification false.

Declared attempts with no records remain `unobserved`; started/partial/producer-
returned attempts without UI settlement remain `unfinished`. Complete, failed,
cancelled, withdrawn and not-started UI outcomes remain distinct. Missing worker,
producer, release or UI rows are missing facts, not proof that work did not run.
Producer/UI cause differences remain visible rather than being forced equal.
Conflicting singleton facts, changed original capsules, invalid clocks, malformed
selected evidence, artifact changes and duplicate rows invalidate comparison.
Known declared attempts and case/arm slots remain even when artifacts fail.
Exit 2 indicates invalid evidence or a packet/output error; reports retain the
available facts when they can be written. Exit 0 means the descriptive packet was
read, not that execution, improvement, source/binary identity or completeness was
proved.

Storage initialization precedes existing input-reader intervals. Its setup spans
are retained separately and are not attributed to an instance merely by PID.
Do not add intervals across processes or call this a full cold-start/usable-input
measurement. Successful follow-up reads do not prove original Task useful work,
visible UI, installation or model behavior. The complete multi-axis objective
still needs independently matched actual execution evidence.
