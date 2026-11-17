# Written checkpoint memo: release original messages

Source repair: `b204a00085dd5d08e7f421ebc4d6f383cf21e86c`, based on
`56dcd7042332032bd5b9f0750a11164ef623c8a1`. Tracks [issue #52798](https://github.com/jeong-sik/masc/issues/52798), a focused reproduction of item 7 in closed issue #43575.

The memo kept the original message array alongside the written values. In the
owned reproduction, one message writes 157 bytes but its omitted ToolResult.json
contains 16 MiB. The payload and original record survived 8 full-major cycles while
only the memo and decoded checkpoint were retained. Releasing the memo cleared
both witnesses. The repair retains entries/chains and written values, with one
weak original-message witness per encoded entry. Loaded entries need no witness.
Decoded identity is checked first so normal decoded reuse never reads the weak
original. All wire validation, bytes and digest rules remain in place.

This is a retention repair with measured costs and a conditional forced-GC
benefit. It does not attribute the running server's whole heap or CPU, or
demonstrate deployed recovery.

## Behavior evidence

- Complete actual Objects MLI/ML compile with fatal4/8/32/69 using existing actual
  dependency archives. No fake interfaces, warning suppression or Dune build.
- The 16 MiB reproduction releases its original/payload while the candidate memo
  and decoded checkpoint stay alive.
- Complete maintained leaf suite: 23 PASS. The same new regression against the
  baseline passes both caller-root controls, then fails at original release.
  That baseline run selects 1 case and skips 22; it is not a full baseline suite.
- The regression continues decoded content-digest queries across collections,
  then confirms that the next save has the same head bytes.
- Existing fragile error matches in this touched test module are replaced with
  exhaustive typed error classification or exact typed VersionMismatch values.
  Earlier failed attempts are retained and described in verification.json.

## Cost evidence

Four AB/BA pairs, eight processes, 100 warm saves per row. CPU columns are medians
of each side's process CPU, divided by100; ratio columns are medians of paired
candidate/baseline ratios. These are different estimators.

| History messages x text bytes | Input | Baseline CPU us/call | Candidate CPU us/call | Paired CPU ratio | Paired allocation ratio |
| --- | --- | ---: | ---: | ---: | ---: |
| 2000 x 128 | original | 256.030 | 309.855 | 1.2082 | 1.1720 |
| 2000 x 128 | decoded | 246.000 | 254.135 | 1.0394 | 0.9999 |
| 512 x 4096 | original | 147.370 | 153.420 | 1.0409 | 1.0901 |
| 512 x 4096 | decoded | 136.965 | 131.150 | 0.9488 | 0.9998 |

The small original-source case adds 53.825 us per call as a difference of side
medians and 31,984 temporary allocated bytes per call. The decoded case adds
8.135 us by that estimator with essentially unchanged warm allocation. The large
original case adds 8,176 allocated bytes per call. Cold encoded-entry creation
also allocates weak metadata (about 0.63%/0.15% extra in these two histories).
The original-source small CPU cost is consistently worse in all 4 pairs. Wall
time varies substantially under host contention and is not latency proof.
Current-domain Gc.counters supplies R2 allocation counts; R1's lagged quick_stat
allocation observations are superseded. Neither measurement is a heap-retention
or current server result.

## Provenance and limits

source-bindings.json records exact baseline/measured/final source hashes. The
final commit changes two comments after the earlier reproduction, leaf-suite
and warm-save native compilation; those executions remain bound to their
earlier complete source bytes. The maintained test bytes match the committed
source, apart from its explicit namespace alias. The newer ToolUse input unit
below compiles and executes the final published source bytes.
Independent reviews distinguish these scopes. capture-provenance.json records
exact copies and host-path substitutions; verification.json summarizes native
commands and hashes their full private include vectors. Existing dependencies
are not a clean full source-graph attestation. No product installation, runtime
profile/GC/restart, CI, original-request replay or merge was performed.

Independent source, maintained-test and cost reviews are retained here. They
record scoped source/evidence assessments, not formal GitHub approvals.

## Persisted JSON input and forced-collection cost

The [ToolUse input experiment](tool-input-gc-README.md) measures duplicated
persisted trees, separately from the omitted ToolResult.json example. Ordinary
Agent_turn tool results use json=None; the omitted-field reproduction alone
does not establish a common operational CPU source.

Four AB/BA pairs, eight fresh processes, compare a released original with a
caller-held positive control. During 24 explicit forced full-major calls, the
released candidate's paired median process CPU ratio is 0.5142/0.4846 for
32768/131072 input rows. Post-GC live-word gauges fall by 14,147,976/56,615,304
bytes. Caller-held CPU ratios are 1.0153/1.0211 and live-word differences are
32 bytes; that control keeps both graphs alive. These are owned-process results,
with a fixed four-row order inside each process and additional untimed Gc.stat
collections. They do not establish ordinary allocation-load CPU, server RSS or
end-to-end recovery. The warm-save costs above remain material.
