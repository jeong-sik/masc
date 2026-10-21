# Original Ask follow-up artifact comparison

The offline reader consumes client Log.Ring JSONL from the opening local
`<base-path>/.masc/logs/tui/session-<pid>-*/`. Copy the relevant complete retained
files into a comparison packet directory before hashing, or use the materializer
below. This command does not
collect data, run a TUI/provider, deploy a binary or establish execution identity:

```sh
python3 scripts/harness/perf/tui_ask_followup_report.py packet/packet.json \
  --json packet/report.json --markdown packet/report.md
```

Both outputs must be new files. Existing files, including input artifacts, are
not overwritten. This source unit has not run this command or its resource case.

## Materialize explicitly selected files

The offline materializer accepts a plan and an explicit source root. It copies
only the listed files into a new private output directory, hashes their exact
bytes and produces the existing v2 packet. It never discovers a cohort from
successful log rows or executes an input file:

```sh
python3 scripts/harness/perf/tui_ask_followup_packet.py plan.json \
  --source-root evidence-src --output packet
python3 scripts/harness/perf/tui_ask_followup_report.py packet/packet.json \
  --json packet/report.json --markdown packet/report.md
```

The plan has `schema_version: 1` and `cases`, with the same explicit case,
instance, independent attempt and declared source-commit fields as the packet.
Its `logs`/`admissions` lists contain canonical relative input paths, and `binary`
is an input path or null. `condition_files` replaces `conditions`: its five keys
are `fixture`, `workspace_snapshot`, `action`, `server_binary`, `terminal` and
values are input paths or null. Their actual byte hashes become the five packet
condition values. Unknown nulls stay unknown. For example:

```json
{
  "schema_version": 1,
  "cases": [{
    "id": "original-ask-case",
    "before": {
      "instances": ["original-before-instance"], "attempts": [],
      "condition_files": {"fixture": "fixture.json", "workspace_snapshot": null, "action": null, "server_binary": null, "terminal": null},
      "source_commit": null, "binary": null,
      "admissions": ["before/admissions.jsonl"], "logs": ["before/events.jsonl"]
    },
    "after": {
      "instances": ["original-after-instance"], "attempts": [],
      "condition_files": {"fixture": "fixture.json", "workspace_snapshot": null, "action": null, "server_binary": null, "terminal": null},
      "source_commit": null, "binary": null,
      "admissions": ["after/admissions.jsonl"], "logs": ["after/events.jsonl"]
    }
  }]
}
```

Supply every original selected instance and independently known attempt,
including attempts lost through capture failure. Empty supplied lists do not
prove complete capture; valid journaled attempts still join the denominator.
The materializer refuses existing outputs, including empty directories/symlinks,
and never overwrites the source files. Input files must pass the reader's same
no-symlink, regular/stable descriptor checks. Files are copied individually, not
as an atomic snapshot of a running workspace. Choose independently frozen inputs;
changing one source after copying does not change the already copied bytes.

`source-plan.json` retains the original plan bytes. `materialization.json` records
source/output path mappings, SHA256/byte sizes, errors, plan/tool source hashes
and its own monotonic preparation span. When analysis is reached, `validation.json` retains the reader's
known attempts and errors. Missing or invalid input keeps status failed and
withholds `packet.json`; incomplete materialization disables descriptive deltas.
A failure writing the output itself can leave partial files and a missing receipt;
exit 2 is never success. A new output is required for another preparation.

Copying/hashing/validation add I/O, disk and memory costs. Each selected path is
read once by capture and each unique byte digest is stored once, then validation
reads copied packet artifacts again. The receipt clock covers work before its
final serialization/write, belongs to this Python process, and must not be added
to original TUI clocks. No file is fsynced and no execution, atomic snapshot,
complete capture, installed binary or measured speedup is certified. Matching
condition-file hashes remain declarations about execution inputs.

## Packet contract

The packet has `schema_version: 2` and a `cases` list. Each case has a unique
nonempty `id` and `before`/`after` objects. Each object contains exactly:

| Field | Value |
|---|---|
| `instances` | Nonempty list of original `origin.tui_instance_id` strings |
| `attempts` | Independent roster of original attempt objects described below |
| `admissions` | List of independent admission JSONL artifact objects |
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
unlogged attempts. Main appends each original admitted read before dispatch to
`admissions/ask-followup.jsonl` in the same private client session, independently
of log severity. Copy and hash this file separately from daily Log.Ring files.
Each journal row has `schema_version: 1`, `event: "tui_ask_followup_admission"`
and the three original attempt fields. It contains no question/answer body or
inferred outcome. Empty journals do not invent attempts.

All journaled and observed reads for selected instances are unioned with the
supplied roster. An attempt may occur in both the roster and journal. Duplicate
journal rows/artifacts and malformed records are evidence errors; original
file/digest/line references remain in JSON. Undeclared observed attempts and
reused instances across arms
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

Admission-write failures use an explicit structured
`tui_ask_followup_admission_failed` event at Startup Warn/Boundary, schema version
1. It retains original `origin`, `request`, `read_admission_started_ns`,
`capture_started_ns`, `observed_ns` and the opaque filesystem `error`. The parser
checks original identity, channel and clock order, preserves artifact/line/row
provenance, and rejects changed origins or duplicate log rows. Message text is
not used to recover identity or select an outcome.

Each attempt retains `capture_failures` separately from producer/UI records and
outcomes. Summary/Markdown count observed capture failures; JSON also retains
each failed capture span and their observed sum. Valid filesystem failure facts
are not malformed evidence and do not by themselves invalidate a cohort with
an independent declared denominator. A warning alone can retain a known attempt
as unobserved; it still does not supply an independent roster declaration, worker
entry, dispatch-not-started or terminal outcome. Missing warnings are unknown
because severity policy or sink/interruption failures can hide them.

The span begins before the capture attempt and ends after error conversion,
before lazy warning formatting/output. It does not prove write/flush was reached
or completed. One entry clock is added to all admission writes;
only failed captures have this additional observed span. Warning construction
remains lazy under the existing Startup module threshold. It is not complete
write-cost accounting or original Task progress.

Declared attempts with no records remain `unobserved`; started/partial/producer-
returned attempts without UI settlement remain `unfinished`. Complete, failed,
cancelled, withdrawn and not-started UI outcomes remain distinct. Missing worker,
producer, release or UI rows are missing facts, not proof that work did not run.
Producer/UI cause differences remain visible rather than being forced equal.
Conflicting singleton facts, changed original capsules, invalid clocks, malformed
selected evidence, artifact changes and duplicate rows invalidate comparison.
Known declared attempts and case/arm slots remain even when artifacts fail.
Valid journaled attempts also remain when daily log artifacts fail. If the
journal itself is invalid, only the supplied roster and other valid evidence
can preserve those identities. The reader never invents missing attempts.
Hash-matched journal bytes do not prove complete capture: initialization/write
failure or interruption before flush can still lose identities. Warnings are
best effort and subject to logger policy.
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

Admission appends reuse the serialized Fs_compat JSONL backend and flush before
the started observation/dispatch. They add synchronous preparation and storage
work after `read_admission_started_ns`; observed admission-to-start, worker and
UI intervals include it. Flush is not fsync, and no latency improvement is claimed.
Failed capture leaves observation dispatch available; it grants no authority.
