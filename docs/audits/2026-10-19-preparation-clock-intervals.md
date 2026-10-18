# Recorded preparation intervals with original clock and source ownership

Source baseline: `53950530ed75e4cb698fbb05f79226324fe35974` (#43825).
Scope: native preparation trial observation encoding and the existing offline
capture reader. No native trial or actual timing comparison was executed.

## As-Is and To-Be

The driver recorded counter-relative ns as floating-point values without an
explicit counter owner. The reader preserved raw timing but emitted no interval
breakdown. Wall-clock intake/replay markers coexist with driver-counter stamps;
their presence does not permit subtracting them or mixing two processes.

| Boundary | Before | After in source |
| --- | --- | --- |
| Driver counter ns encoding | Float | Canonical unsigned 64-bit decimal string |
| Counter owner | Implicit driver invocation | Fresh opaque invocation reference and explicit counter domain |
| Per-attempt interval visibility | Raw timing only | Five named reported intervals or explicit unavailable reasons |
| Useful commit attribution | Native reported leaf retained | Recorded original fixture/Task/turn/intake/commit metadata must join before derivation |
| Missing useful evidence | Raw fields retained | Useful span withheld; valid cycle spans retained |
| Failed/unfinished attempts | In full declared cohort | Same cohort, with independently available partial timing |
| Wall or legacy float timing | Raw fields retained | Still retained; no counter coercion or subtraction |
| Speedup/execution verdict | Unverified/null | Same unverified/null verdicts |

`Mtime.Span.to_uint64_ns` and unsigned Int64 decimal formatting preserve ns
without a float round trip. The reader validates that producer range and
canonical string representation before integer subtraction. Range validation
is the timestamp wire contract, not a new workload cap or scheduling budget.
UUID clock references are observation identities, never execution permission.

Each interval is local to one receipt and must use its tagged counter reference.
No cross-arm absolute counter subtraction, wall-to-counter conversion, inferred
missing boundary, arbitrary timeout or performance threshold is introduced.
Unavailable, foreign-clock and negative intervals remain explicit observations.

## Useful-source metadata boundary

Useful spans join frozen fixture bytes against common-input/receipt hashes,
the original Task and trace, the exact recorded turn, source admission and
intake marker/hash, complete Tool commit coverage/digest and unique full commit
identity matching the original selection input. The nominated commit must lie
inside the reported cycle. No provider bodies, raw SDK execution or stdout
content are replayed or validated by this reader. Artifact consistency is not
proof of source/build, physical independence, original Task completion, first
successful-leaf semantics or model identity. Those remain native protocol and
runtime verification responsibilities. Missing files are not a stopped-process
verdict; reporting is a non-atomic read of available capture artifacts.

The driver encoding adds observation overhead; the reader adds file/hash/JSON
work outside native execution. Neither overhead nor CPU/memory savings have
been measured. There are no cohort averages, latency percentiles or speedup
ratios; reported failed/unfinished durations are not filtered out.

## Authored scenarios and checks

Extend the protocol suite with an offline capture scenario containing failed
and unfinished receipts, exact ns above `2**53`, original source/Task/commit
artifacts, foreign Task and counter substitutions, a negative span, legacy float
stamps and a missing commit journal. Evidence hashes/membership must remain
unchanged by reporting, precision must remain exact, and unrelated valid cycle
spans must survive unavailable useful evidence. Existing native paired success
assertions require joined intervals and distinct per-process counter owners;
existing timing comparisons consume exact integer strings. Scenarios are
authored and unexecuted, not helper-count/layout/wording/PTY tests.

Only OCaml parsing, Python AST parsing and diff/changelog hygiene are author
checks. No typecheck/build, test/coordinator/driver/model execution, CI dispatch
or watch, install/restart, actual cohorts or visible TUI proof. Independent
current-head source approval and merge remain separate evidence boundaries.
