# Preparation capture comparison without replacing evidence

Source baseline: `6c0906a9aa700f17751f85788e6b0b8c5fe0a0a7` (#43824).
Scope: the existing `preparation_trial.py` coordinator and its recorded captures.
This is source implementation, not an executed trial or latency result.

## As-Is and To-Be

Finalization added two correct receipts to `matching` before checking common
inputs. A mismatch then rewrote both original attempt outcomes to failure but
left the pair in `matching`. Python equality also accepted JSON `true` as equal
to `1`. Reading a missing/malformed receipt aborted the full summary. The CLI
required a built driver and new trial even when only a recorded report was needed.

| Boundary | Before | After in source |
| --- | --- | --- |
| Two correct receipts with mismatched input | Pair remains in matching | Mismatch recorded; no matching pair |
| Original receipt on pair mismatch | Both outcomes overwritten | Original files untouched; derived assessments carry separate reported outcomes |
| Repeated JSON boolean/number mismatch | Python equality can accept it | Type-preserving structural comparison rejects it |
| Missing/invalid/cancelled receipt | Missing/invalid can abort finalization | Every declared attempt retained with independent read state and reported outcome |
| Re-read a capture | No offline CLI | Read-only `--report-from`, no driver/run arguments |
| Normal and offline summary | No offline path | Same recorded-capture reader |
| Source/build/execution/speedup | No speedup claim | Explicitly unverified; null timing/speedup verdicts |

The denominator is the complete manifest-bound experiment, not the subset of
correct receipts. Unsupported outcomes retain their reported values and partial
fields while their coordinator assessment remains unfinished. Bytes are hashed
before parsing so malformed readable receipts retain an artifact identity.
Native outcome, comparison result and filesystem-read state are separate axes.
An invalid manifest/experiment declaration refuses reporting: it cannot supply
a trustworthy denominator. No arbitrary pair cap or sampling limit is added.

Declared paths are rebuilt from experiment pair/arm identities and must exactly
match the manifest. Reads reject descendant symlinks and nonregular entries.
Reports do not claim an atomic filesystem snapshot. Matching means only agreement
of receipt-reported common fields, with reported inventory coverage separate;
it does not validate physical execution, original Task progress or model identity.

The report path returns before any driver invocation or write. Normal run setup
and native execution remain explicit run behavior; only final comparison moves
to the shared reader. Fixture/driver invocation errors write a separate process
observation rather than rewriting the native attempt. No retry, timeout, new
workflow, tool scheduler or performance threshold is introduced.

## Authored scenario and evidence limits

Extend the existing protocol test with an offline filesystem/CLI cohort: input
`true` versus `1`, cancellation, a missing arm, malformed JSON, an explicit
failure and a valid pair with unreported inventory. All eight declared attempts
must remain, only the agreeing pair can match, repeated report reads must keep
every original file hash/membership unchanged, and report-plus-driver arguments
must be rejected. The scenario is authored and unexecuted; it is not a native
trial, timing experiment or direct helper/predicate mirror test.

Only Python AST parsing, diff and changelog hygiene are author checks. No imports
or execution of the coordinator/tests, native driver/model/PTY run, local build,
CI dispatch/watch, installation/restart or actual Before/After cohort. Existing
native protocol assertions remain relevant but have not been rerun. Independent
source review, merged state and visible TUI behavior are separate evidence.
