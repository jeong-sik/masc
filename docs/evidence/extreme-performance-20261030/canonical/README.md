# Canonical request fast path: native function evidence

This is one bounded unit of the active TUI/server performance investigation.
It does not certify the 0.1 ms product goal, deployed performance, Add-on lane
throughput, parallel scaling, file I/O, or retained-receipt integration.

The baseline is `0b18418111a533b3dc10c33b8811b1d058f136fe`.
`before.ml` and `after.ml` contain the exact helper/function span described in
[provenance.json](provenance.json), plus a local Result bind operator. They
compile independently with the installed OCaml 5.5.1 and Yojson. This experiment
does not compile the complete product module. Product changes are in
`lib/lane_addon/lane_addon_action.ml`; a product-level regression case was also
added to `test/test_lane_addon_actions.ml`, but that suite was not run locally.

The candidate proves strict object-key order before omitting duplicate-key
sorting and the final sort. Unordered objects retain the original duplicate
check, original child visitation order, and final sort. It introduces no cache,
mutable product state, weaker digest check, or change to durable publication.

All three runs remain intact. Run 1 was exploratory while the isolated scale
run was active. Run 2 increased each batch's iterations and included a late
inversion and late duplicate. Run 3 added long common key prefixes, an early
child error, and explicit negative-outcome counts. Runs 2 and 3 followed scale
child cleanup; other host workloads were not stopped. They are separate
experiments, not a replacement or correction of earlier measurements.

Each case has 12 alternating AB/BA rounds. The summaries report medians of
**batch means**, not per-call latency percentiles. Full-major GC precedes each
batch; its duration is outside the measured region. Wall, process CPU and
allocation include the loop overhead consistently. Inputs are synthetic and
prebuilt. Actual production input proportions were not measured.

Run 3 observations:

| Case | Before wall us/call | After wall us/call | Allocation change |
| --- | ---: | ---: | ---: |
| Sorted 300 fields | 30.237 | 5.339 | -66.68% |
| Nested 300 rows | 318.120 | 150.486 | -45.05% |
| Long-prefix keys, late inversion | 61.426 | 69.066 | +0.02% |
| 300 fields plus a duplicate | 13.521 | 15.353 | +0.01% |

The late duplicate is rejected before its NaN child is evaluated. Its observed
wall regression is +13.55%, CPU +8.34%; this is one specific 301-field input.
The long-prefix inversion has +12.44% wall and +10.49% CPU. Preserve these
negative results when assessing the sorted-input benefit. The nested candidate
batch mean still exceeds 100 us; no tail-latency target is established here.

Run 3 compares 25,016 outcomes: 9,814 accepted, 7,705 duplicate refusals,
4,960 non-finite refusals and 2,537 parser refusals; no exceptions were observed.
The first JSONL row retains the exact refusal texts and four independently
specified negative expectations. The generated inputs share the documented
seed across runs, but case counts differ with the added benchmark inputs.
This comparison does not replace product digest/receipt integration checks.

To reproduce a captured pair, copy `before.ml`, `after.ml` and the chosen
`bench-vN.ml` as `bench.ml` into a **new** directory under repository
`artifacts/`, then run:

```sh
ocamlfind ocamlopt -package yojson,mtime.clock,unix -linkpkg \
  -w +4+32+69 -warn-error +a -o canonical-bench before.ml after.ml bench.ml
./canonical-bench > observations.jsonl
```

Retained hashes refer to these frozen source bytes. Re-extract and bind current
product source separately before attributing a later run to it.

`url-boundary-observations.json` is a separate credential-boundary check of the
latency runner. A sentinel at HTTPConnection construction proves that empty
userinfo and a password with an empty username are rejected before any
connection or output artifact; a credential-free origin reaches the sentinel.
The before runner accepted the empty-username cases. Only literal placeholder
values were used. This is not a performance improvement or a live auth probe.
