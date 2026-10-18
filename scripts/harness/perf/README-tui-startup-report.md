# Offline startup-record comparison

Python 3.11+; standard library only. Reads supplied files and writes to stdout.
It starts no TUI, PTY, server, model, build or installer.

```sh
python3 scripts/harness/perf/tui_startup_report.py /path/to/packet.json
python3 scripts/harness/perf/tui_startup_report.py /path/to/packet.json --format markdown
```

The output describes recorded intervals under matching **declared** conditions.
Hashing candidate bytes does not prove they ran or came from the declared source.
Source-to-binary, execution, paint and useful-work verification remain false;
`measured_speedup` stays null. There is no performance PASS verdict. Exit 0 means
report generation succeeded, including reports containing invalid/missing samples.
An invalid packet envelope or unreadable packet returns 2. Inspect outcome counts
and each comparison basis.

## Packet version 1

The top-level object has exactly `schema_version: 1` and `cases: [...]`. Declare
the full denominator before collection/selection. An empty list remains empty.
Each case has exactly `id`, `conditions`, `before`, `after`. Its nonempty `id`
must be unique. Every condition object has exactly four lowercase SHA-256 strings:
`fixture_sha256`, `workspace_sha256`, `terminal_sha256`, `input_reply_sha256`.
They declare fixture/workspace state, terminal profile and the exact input/reply
sequence. Each arm repeats its own declarations; a mismatch prevents its delta.
Equality does not verify actual execution. Keep original collection receipts.

Each arm has exactly:

| Field | Contract |
|---|---|
| `source_head` | Declared 40-character lowercase Git SHA, or null when unknown |
| `binary` | File reference, or null when bytes are absent |
| `log` | File reference for original Log.Ring JSONL, or null when absent |
| `capture` | `{"pid": positive integer, "dispatched_ns": "canonical decimal"}`, or null |
| `conditions` | This arm's four condition declarations |

A file reference is exactly `{"path": "relative/file", "sha256": "<64 lowercase hex>"}`.
The digest placeholder is notation, not a usable value. Paths are canonical POSIX
paths relative to the packet directory, without absolute/dot/parent components or
nonregular files. Embedded NUL and unencodable filesystem paths are invalid
artifact evidence for that arm; they do not discard the other cases. Fill digests
from frozen artifact bytes. Each declared path is
read once per invocation, and each distinct log digest is indexed once. This is
a report-local input snapshot, not a persistent cache or global filesystem freeze.

Use a null log/capture for predeclared attempts whose records were not obtained,
including a Before binary without instrumentation. Do not invent zero duration
or copy another attempt. Missing/invalid arms and cases remain in the denominator.
Duplicate case identities invalidate both cases. Reusing the same nonempty
`(log digest, pid, dispatched_ns)` across arms/cases suppresses those deltas. This
detects artifact reuse, not independent execution of different artifacts.

## Record contract and output

The reader accepts `Log.Ring.entry_to_json` from `lib/masc_log/log.ml` and the exact
Transport/INFO message tag `tui_startup_observation=`. It does not search arbitrary
text, stderr or terminal output. Payloads match `bin/masc_tui_startup_observation.ml`,
including wire phase `handed_off` for actual decoder installation. Unknown
schemas/discriminants are invalid; there are no legacy fallbacks.

Immutable facts must agree across rows. Late capture cannot overwrite caller
interruption or first input. Capability applications use their actual timestamps
and first-answer availability. Logging order is not causal order; intervals come
only from matching fact endpoints, and recorded intervals must agree with them.
Identifiable foreign captures stay separate, including corrupt foreign captures.
Unattributable malformed data invalidates selected samples from that artifact.
Duplicate selected rows and conflicting facts stay invalid, not conveniently
replaced with a latest row. Snapshot facts can be available without each original
phase event; coverage and observed phase names are reported separately.

Eight intervals remain exact decimal nanosecond strings or null. A valid log,
matching file hashes, present source declaration, matching declared conditions
and non-reused capture selection permit `after_minus_before_ns`. These descriptive
checks do not certify execution. Missing endpoints stay missing. Failed/interrupted
attempts remain in outcome counts and in metric populations whose endpoints exist.
Monotonic clocks are never subtracted across processes; internal intervals are
compared. No pooled percentile, speed or readiness verdict is added.

JSON retains all cases, separate evidence/caller/capture/input counts, per-metric
paired counts against `declared_cases`, selectors, hashes and exclusion reasons.
Markdown shows worker wait, capture and first-input reception plus all outcome
counts. Reception is not acceptance, useful Task work or physical paint.

## Evidence status

Four compound scenarios in `test/test_tui_startup_report.py` cover interrupted,
late and absent attempts; foreign ownership/conflicts/duplicates/bad digests; and
Int64 precision with mismatched conditions, duplicate cases, truncation and reuse;
and a healthy cohort mixed with NUL/unencodable log paths and an invalid candidate
path, retaining separate valid-log and candidate-identity axes.
They use explicit synthetic files/protocol records, not measured runs, and remain
unexecuted. AST parsing imports/executes neither report nor tests and is not type,
runtime or assertion evidence. No native observation or speed measurement accompanies
this tool. Full-file snapshots and validation/indexing have unmeasured memory/CPU cost.
