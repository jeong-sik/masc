# Preserve recorded setup and process closeout beside preparation outcomes

Source comparison base: `d24e30bc4c392c4833d90bc86843efc897efaf7c`
(#43898). This unit exposes existing process records through the same offline
reader and corrects the coordinator's persistence exception boundary. No report,
coordinator, driver or test is executed.

## As-Is / To-Be

The coordinator saved per-attempt `process.json` after a driver returned, or
recorded a fixture/invocation exception separately from the native receipt.
`report_capture` omitted those files. Thus a missing/unfinished receipt retained
its denominator and partial timing but lacked recorded closeout context in the
report. The invocation `try` also included saving a known return, so an error
persisting that return could be caught as fixture/driver unavailability.
Shared `setup.json` was also omitted, leaving no reported preparation context
when setup failure prevented both attempts from writing process records.

| Boundary | Before | Implemented behavior |
| --- | --- | --- |
| Recorded process closeout | File outside report | Separate observation per declared attempt and paired timing arm |
| Shared setup context | File outside report | Original object/hash/read state once per declared pair |
| Original native outcome/assessment | Kept separately | Same values; process record never replaces them |
| Readable record identity | Not projected | Exact bytes hash and declared relative path |
| Record variants | Written but not interpreted by reader | Strict returned-code/epoch or unavailable/detail record |
| Unknown/partial/malformed record | Not visible | Invalid with hash and decoded original data where available |
| Missing/nonregular process record | Not visible | Explicit read state without aborting cohort or erasing intervals |
| Known-return save failure | Can enter invocation-error fallback | Propagates to CLI error boundary without recasting completed invocation |
| Summary denominator | Full declared receipt cohort | Same cohort plus independent process read-state counts |
| Current process liveness | Unverified | Still unverified; no record-based running/stopped inference |

## Original authority and interpretation

`process_observation` reconstructs the sibling path from the manifest-admitted
attempt path; a record cannot redirect a read. The existing regular-file and
no-descendant-symlink boundary handles it through `record_observation`. Bytes are hashed before decoding so
malformed readable JSON retains artifact identity. Decoded unknown shapes stay
in `reported_record`; unsupported metadata does not silently gain a closeout
kind. An unreadable file has no fabricated hash or original record.

The reader recognizes exactly the current producer's two field sets. Integer
return codes exclude booleans; numeric epochs exclude booleans and the existing
JSON decoder refuses non-finite values. A null code with the explicit unavailable
tag/string detail remains that reported variant, without an invented timestamp
or proof that no process started. Negative codes are retained without inferring
platform-specific signals. There is no new code/range/workload cap.

This path association is recorded metadata, not a physical invocation identity
certificate. A missing, replaced or malformed file cannot establish current
liveness. Even a typed record's `current_liveness_verified` and
`execution_verified` are false. Receipt admission, native reported outcome,
coordinator assessment, process record admission, counter intervals and pair
comparison remain distinct axes. A zero recorded return does not fill in a
missing native result, and an unavailable record does not erase a received one.

Each process file is read through the attempt projection once; the paired
timing arm reuses that observation. No directory scan, extra process probe,
signal, launch, retry, cache or scheduler is added. Wall-clock record fields do
not enter counter arithmetic or overwrite the original timing/source/Task join.
Read states are counted independently over every declared attempt.

Setup uses the same read/hash/object projection once per declared pair, with
its own denominator and `setup_states`. The coordinator's pre-setup unfinished
record and native driver's `setup_complete`/observed/fixture object are kept as
uninterpreted metadata. Reading an object does not validate setup, reuse its
counter in an arm, authorize tool work or replace the independently received
native results. Missing/malformed setup context cannot erase either arm.

The known-return save now runs in `else` outside the fixture/invocation exception
handler. A persistence error reaches the existing outer CLI error boundary
instead of manufacturing an unavailable-invocation record. The manifest and
preallocated attempts/native receipts are retained for later offline reporting;
this does not promise a persisted process record when storage failed. The
producer error path is source-inspected, not fault-injected or executed.

## Quantitative Before / After limits

Process context changes from no report projection to one admitted/invalid/missing
observation per declared attempt, also available beside paired timing. The
shared setup context likewise covers every declared pair with its own read state. The
denominator is unchanged; failed/cancelled/interrupted/unfinished/missing/invalid
receipts remain present. Extra file/hash/JSON work adds unmeasured offline
overhead. No preparation-time, HTTP/model-call, memory, latency-percentile or
speedup improvement is asserted. Actual source/build/physical execution and
useful Task/input/paint evidence remain separate.

## Authored compound scenario, not executed

The existing eight-attempt filesystem/CLI scenario now includes actual temporary
process files for zero, positive and negative codes, unavailable invocation,
missing record, malformed JSON and a boolean code. It deliberately includes a
zero code beside a missing native receipt and an unavailable record beside a
received correct native result: the report must retain each axis, not resolve
the disagreement by replacing either source.
Shared setup records include a controlled setup-complete object, the original
unfinished/pre-setup shape, a missing record and malformed JSON. Their counts
use four declared pairs while process/receipt counts use eight attempts.

The scenario checks the complete process/receipt cohort, original cancellation
metadata, malformed bytes hash, parsed invalid data, original pair/strategy
association, unverified liveness/execution flags and unchanged files/hashes and
membership over repeated CLI reads. Existing pair input mismatch, failed timing,
counter/Task/source joins and missing receipt cases remain. The fixture codes
are controlled records, not observed process exits or runtime measurements.

All assertions are authored and **unexecuted**. Author checks are Python AST
parsing and diff/changelog hygiene only. No import, test/report/coordinator/driver,
native/model/PTY run, local build/typecheck, CI dispatch/watch, installation,
restart or live write occurs. Current-head independent source approval and merge
are separate. The full six-part Ask/Task, preparation, Composition, held/shared
batches, input/visibility and matched actual Before/After goal remains open.
