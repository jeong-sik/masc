# Group retained slot observations once

The dashboard slot projection previously deduplicated keys by linear membership
and repeated list append, then scanned all retained observations for every key.
It also searched declarations and current bindings for each row. The candidate
groups by the typed `(transport, slot_id)` key once, indexes the first current
binding, and retains a separate first-seen list for output order. Both tables
and mutable grouping records live only within that call; no global cache or
public API is added. The original dated selection predicates and strict
`(time, run_id, observation_index)` comparator remain unchanged.

The source commit is `ace897ba621040f9f43cec37f6092aee9c74acb2`, based on
`0542d471eedf56d72cf829b4bd1ad0bf99b417ab`. The unchanged public MLI and exact
source/test hashes are in [native-inputs.json](native-inputs.json) and
[response-review.json](response-review.json). Later changelog-only commits must
be compared against these same blobs before reusing this evidence.

## Measured calculation and tradeoffs

Four AB/BA pairs use eight fresh processes and six fixed-order synthetic input
rows. Three warmups and one full collection per row occur outside timing.
Fixture/catalog construction, initial output checking and final JSON string
rendering are also outside timing. The timed loop includes the complete
projection's grouping, lookup and JSON-tree construction, loop/sink/clocks and
natural GC. CPU is process `Sys.time`; managed allocation is
`Gc.allocated_bytes`. Wall times remain in [cost-raw.json](cost-raw.json).

| Input | Slot IDs / output keys | Inspected / matching observations | CPU us/call, side medians before / after | Median paired CPU ratio | Allocation ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| Empty | 0 / 0 | 0 / 0 | 0.01517 / 0.00319 | 0.217856 | 0.000007 |
| One observation | 1 / 2 | 1 / 1 | 0.55120 / 0.64945 | **1.244625** | **1.045543** |
| Foreign owner only | 0 / 0 | 464 / 0 | 14.08250 / 10.82450 | 0.771752 | 0.345843 |
| Small | 4 / 8 | 120 / 110 | 40.20150 / 24.45925 | 0.604155 | 0.898400 |
| Wide | 16 / 32 | 920 / 836 | 861.895 / 291.1275 | 0.336987 | 0.848921 |
| Large | 64 / 128 | 7,312 / 6,647 | 18,568.875 / 4,108.500 | 0.221262 | 0.797830 |

Slot IDs and transport/slot output keys are different counts. Inspected and
matching counts are derived from the controlled fixture, not a live workload.
Missing/error run observations are omitted before inspection. All 24 paired
rows have equal output byte length and SHA-256. There are 48 measured rows and
913,760 timed calls; [analysis.json](analysis.json) retains every pair ratio,
all six summaries, input dimensions and limits.

The one-observation row is slower in all four pairs: median paired CPU rises
24.46%, managed allocation rises 4.55%, or **376 B/call**. Its side-median CPU
difference is 0.09825 us; that is a separate estimator from the median paired
ratio. The empty row has nanosecond-scale absolute CPU and is a synthetic
control. No workload weighting, universal speedup, live CPU percentage, RSS or
peak-live-memory benefit is inferred. Hash-table grouping is expected amortized
work; collisions and long string keys preclude a worst-case linear guarantee.

## Behavior checks and failed attempts

The complete actual baseline/candidate ML and MLI were compiled under fresh
basenames with fatal warnings 4, 8, 32 and 69. The actual maintained `exact_run`
helper and entire augmented slot-binding case were copied verbatim, with only
leading opens/module aliases. That one complete case runs once against each
implementation. It checks original endpoint/time, owner and transport isolation,
duplicate declarations/current bindings, first-seen order, dated ties and
undated order. This is **two calls of one maintained case**, not two distinct
tests or execution of the whole maintained Dune target.

The owned oracle additionally passed **240 complete encoded JSON comparisons**.
Its run-count generator does not reach the `None`-observation branch; larger
cost cases do, and their paired output hashes match. It generates no
`lane_key=None` input. This is bounded coverage. [oracle.stdout](oracle.stdout)
contains the result; [oracle.stderr](oracle.stderr) has 38 normal Alcotest
ASSERT trace lines. All 17 final compile/link/oracle/cost commands exited 0;
see [native-receipts.json](native-receipts.json).

Two earlier failures remain in [failed-attempts.json](failed-attempts.json).
The first was a wrong capitalization in the extraction alias. The second
correctly rejected the new test's record update of the private
`Exact_output.binding_observation` type. The final test/probe instead obtains
both endpoint bindings through the public catalog/admission factory. No
interface was exposed or fabricated and no assertion was weakened. The
original [source review](source-review.json) missed that test-legality boundary;
its test snapshot is superseded by the independently inspected factory repair
in [response-review.json](response-review.json). The production ML stayed the
same throughout. No historical failure or review was rewritten.

## Runtime lead and limits

A retained Ops sample of PID 50800, labelled source `a3c3c71`, contains three
main-thread slot-projection stack observations. That target ML blob equals the
source base above. [profile-lead.json](profile-lead.json) preserves the selected
actual ancestor paths and original raw digest. These are stack residence
observations, including native comparison frames, not a CPU share, call count
or proof this function explains sustained whole-server load. The short sample
and reported image identity are separate from source-build provenance.

The native capture uses broad real prebuilt dependencies. It proves neither
the full maintained target's declared visibility nor a clean dependency/ABI
rebuild. [probe.ml](probe.ml) retains the executed fixture. [driver.py](driver.py)
is an output-path derivative that writes new runs under ignored `artifacts/`
and reads original source copies from the retained private capture. Its
[provenance](replay-driver-provenance.json) distinguishes its hash from the
original executed driver; the derivative was not rerun. It still references
pre-existing local include/link metadata, so it is not a clean-checkout recipe.
No Dune or CI run, installed candidate, live profile/GC/provider call, restart,
merge or recovery of an original request is included. All explicit collections
were confined to the owned cost processes.
