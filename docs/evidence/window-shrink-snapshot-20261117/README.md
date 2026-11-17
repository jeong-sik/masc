# Share one history byte measurement across shrink bounds

Claude Code calculated a history's total byte size, next retry boundary and
zero-history floor with separate passes that re-encoded the same messages.
Codex Start repeated the total and next-boundary passes. The source change
measures each original list occurrence once and, when atoms exist, measures
the omission preamble once. Both bounds consume the resulting opaque scalar
snapshot inside the existing CPU job, before `Host.project_source` adds request
evidence. The finished value holds only integers and a private suffix array.

The initial source candidate is `8509f161b1d498fbc0001c3fdfae047b012de3b6`,
based on `c97d0f9b850c812885a7f89a4fcdc280a6738416`. A later CI correction,
`2d580ed1dd08efb8417e349941018f7aa5998e61`, changes one Window-test renderer.
All four product files and the other two maintained tests retain their original
blobs. The original seven hashes remain in the earlier manifests; the corrected
test hash is in [ci-test-correction.json](ci-test-correction.json). No installed
candidate or live server observation is included here.

## Measured scope

The owned fixture replays only the adapters' calculation after the carried
history has been projected. It links complete actual baseline and candidate
Window units and the complete actual canonical codec with existing real
dependency archives. Both baseline lanes perform their unconditional full
byte fold, including bounded requests. The bounded declared capacity is
2,000,000 bytes (target 1,000,000); the unbounded target is the full measured
size divided by two. Claude also queries the floor; Codex does not.
Histories are direct synthetic inputs to this calculation; the benchmark does
not establish that Host would produce those histories at the selected cap.

Four AB/BA pairs use eight fresh processes. Each process runs the same fixed
16 rows: both lanes, bounded/unbounded, and four history sizes. Each row has
three untimed warmups and an untimed full collection before its timed loop.
The loop includes snapshot construction, bound queries, loop/sink and clock
costs. CPU is `Sys.time`, allocation is `Gc.allocated_bytes`; wall and
`Gc.counters` deltas are retained. Encoder calls/byte volume are counted in a
separate untimed calculation. No ratio combines different fixtures or lanes.

For the 301-message, 3,350,376-byte history with 100 tool results of 32 KiB:

| Unbounded calculation | Baseline | Candidate |
| --- | ---: | ---: |
| Claude encoder calls | 1,207 | 302 |
| Claude encoded byte volume | 13,402,572 | 3,350,802 |
| Claude CPU per call, side median | 59,542.56 us | 15,544.92 us |
| Claude allocation per call | 41,767,595 B | 10,491,083 B |
| Codex encoder calls | 904 | 302 |
| Codex encoded byte volume | 10,051,554 | 3,350,802 |
| Codex CPU per call, side median | 47,068.09 us | 15,785.28 us |
| Codex allocation per call | 31,304,763 B | 10,491,067 B |

The median paired candidate/baseline CPU ratios are **0.261691** for Claude
and **0.341228** for Codex (73.83% and 65.88% lower in these calculations).
Allocation ratios are **0.251178** and **0.335127**. Ratios use the median of
four pair ratios; the separately shown side medians are a different statistic.
For example, Codex's four CPU ratios are 0.339323, 0.343133, 0.325694 and
0.554279. All individual observations are retained in [cost-raw.json](cost-raw.json).

Every one of the 64 paired rows returned identical full size, next boundary
and floor where applicable. [analysis.json](analysis.json) includes all 16
row summaries, CPU/allocation ratios, exact counts and measurement limits;
the smaller and bounded rows are included there as well.

## Behavior and compilation

- The complete maintained Window suite passed **41 tests**, including signed
  zero, repeated physical occurrences, original error precedence, materialized
  preambles, no-atom behavior and a caller-held/weak-release ownership control.
  Its full output is [window-suite.stdout](window-suite.stdout). That earlier
  execution used both Window and codec aliases and did not establish the
  maintained test's declared library visibility. The CI correction below
  records the dependency failure and new checks separately.
- The corrected differential fixture passed **24,084 assertions** across 54
  histories and six stable measurement policies. It compares next/floor,
  atom labels and exact encoded projections or typed errors, including sparse
  carried projections. It covers all current origins/roles, true
  `Agent_instruction` working/unread markers, orphan tools, duplicate
  occurrences, materialized preambles, signed zero, zero sizes and native-int
  overflow arithmetic/target boundaries. Inherited integer behavior is
  compared, not replaced with a new overflow policy. See
  [compare.ml](compare.ml) and [differential.json](differential.json).
- Ten complete ML/MLI compilation commands passed for baseline/candidate
  Window, canonical codec, and both actual candidate adapters. Each adapter
  uses its complete original MLI and complete actual ML with one leading
  alias to the fresh Window unit; original nominal observation paths remain.
  Fatal warnings 4, 8, 32 and 69 remain enabled. This is actual complete-unit
  seam typing with prebuilt dependencies, not an original-name dependency
  rebuild. [command-receipts.json](command-receipts.json) separates terminal
  phases and [input-manifests.json](input-manifests.json) records captured
  source, unit, executable and dependency hashes.

A later independent attempt to execute existing public adapter `For_testing`
seams stopped before execution. Complete baseline adapter MLI compilation
found incompatible `Keeper_toml_loader` assumptions between current prebuilt
`Runtime_agent` and Host interfaces. The candidate-only fixture then found
incompatible `Tool_blob_store` assumptions between the current Host interface
and the earlier fresh adapter CMI. Both attempts exited 2; actual adapter
calls were **zero**. The earlier ten successful compilation receipts remain
their distinct capture-time result. No fabricated interface, ABI patch or
dependency rebuild was used to turn these later failures into a pass.
See [adapter-review-r1.json](adapter-review-r1.json) for both exact diagnostics
and the unexecuted fixture's scope.

The initial full maintained-suite compile failed on seven existing fragile
matches. The first explicit-constructor repair omitted `ReasoningDetails`
in three helpers and was also rejected. Both failures remain in
[failed-attempts.json](failed-attempts.json); the final explicit matches passed
without weakening assertions or warning policy. The earlier cost fixture
omitted the bounded baseline's outer fold and used two incorrectly tagged
marker rows. Its cost series is superseded in full by corrected `cost-r4`.

## CI test dependency correction

`Merge compile` run [44083963891](https://github.com/jeong-sik/masc/actions/runs/44083963891),
job `134041528895`, failed for top head
`30123545d27f87309c640efbb335ebf6b74e3b5a`: the new Window regression referenced
`Keeper_official_client_context_codec` by a bare name unavailable in its actual
wrapped-library visibility. The module is not listed in `lib/dune`'s
`private_modules`. The earlier native check compiled the codec under an alias
and therefore missed this dependency error. Its successful behavior results
are not proof that the original maintained test could compile as declared.

The one-line test repair uses the public
`Agent_core.Checkpoint.message_to_json` rendered by `Yojson.Safe.to_string`.
The measurement API accepts an injected stable renderer; the test still checks
signed-zero byte distinction, exact original occurrences/order and reuse of
the measured result. It makes no claim that this renderer equals the
official-client wire encoder. Product implementation and measured cost inputs
are unchanged.

The new bounded check preserves the CI command's 179 visible `-I` and 417
hidden `-H` entries, translating only the runner/opam/build roots. Complete
actual Window MLI/ML files compile under their original basename. The original
test then fails with the same unbound-module diagnostic, while the corrected
unmodified maintained test compiles. Generated `Dune__exe` sibling-test alias
opening and output/CMI paths are omitted; this is not an original Dune invocation
or clean dependency rebuild. No codec alias or newly exposed library is used.

A separate native execution changes only the Window alias and uses the earlier
broad real-archive link vector. All **41 tests pass**, including the repaired
regression. [ci-test-correction.json](ci-test-correction.json) records command
results, input/output hashes and limits;
[ci-test-original.stderr](ci-test-original.stderr) retains the reproduced
failure and [ci-test-fixed.stdout](ci-test-fixed.stdout) the full suite output.
These checks do not establish a new CI result, full adapter-suite success,
installed behavior or live CPU/RSS improvement. Earlier receipts and reviews
remain unchanged historical records.

The independent [source review](ci-test-source-review.json) is bound to the
one-line fix and the exact focused captures. It found no P0/P1/P2 in that scope;
it is separate from a current-head formal GitHub account approval.
The [response review](ci-test-response-review.json) separately checks the
correction prose, selected receipt hashes and the declared/executed scope.

Independent source review and response are retained as
[source-review-r1.json](source-review-r1.json) and
[review-response-r1.json](review-response-r1.json). Their verdicts are bound to
the listed source snapshots and scopes, not formal GitHub account approvals.
The corrected fixture findings are closed in
[review-response-r2.json](review-response-r2.json).
The independent [cost review](cost-review-r1.json) verifies raw rows,
arithmetic and capture binding. Later wording/packaging responses are recorded
in [corrections.md](corrections.md) and
[review-response-r3.json](review-response-r3.json).

## Limits and capture layout

This result measures the owned post-windowed calculation. Full request
projection, job scheduling, provider retries, Codex Resume execution, installed
code, live workload distribution, total server CPU, RSS and recovery of a
stalled request remain unmeasured. Temporary measured tuples and suffix
arrays add metadata work; no transient peak-memory reduction is claimed.
Only stable rendering byte sizes have equivalence: a callback that changes
its answer on repeated invocation is outside the new occurrence-once API
contract.

Private failed attempts and full raw commands remain under
`artifacts/cpu-memory-20261116/window-shrink-snapshot-20261117/`. This selected
capture preserves raw observations and input/command hashes. Replay scripts
reference that local pre-existing include/link metadata and dependency
archives; they are capture drivers, not a self-contained clean-checkout
build recipe. Dependency hashes identify captured inputs; the archive list is
not a closed dependency graph and does not establish full source-build
provenance. No Dune/full product build,
CI watch, live runtime profile or forced-GC request, install, restart or merge
was performed for this unit. Full collections ran only in the owned test and
benchmark processes described above.
