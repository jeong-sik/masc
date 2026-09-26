# Integer-bound input-frame comparison

[Run 36259405687](https://github.com/jeong-sik/masc/actions/runs/36259405687)
completed three alternating pairs (AB, BA, AB), 600 acknowledged input frames,
and six draft-preservation checks. The comparison artifact `10911169382` has
original ZIP SHA-256
`856b5191e6e86586e753c136a60dcd8ece4f3d6f4eb2f91cb3240cc7ef27d354`.

## Identity and protocol

- Baseline `56884cdc2d82d8b4b3f9b64597c6e770228e9712`: run `36255838724`,
  artifact `10911156552`.
- Candidate `0782db656ccf5c9da1ee743ea21ef932567c978a`: run `36257316359`,
  artifact `10911402956`.
- Observer `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.

Each session runs ten cycles of six roster actions and four Info actions,
with 250 retained Channels bindings plus one other Keeper. Before another
input is sent, the observer requires the expected viewport and frame-end
acknowledgement. All 27 original artifact members are retained under `raw/`.
`redaction.json` records original and published hashes; the sole replacement
is the CI checkout prefix with `<CI_CHECKOUT>`.

`source-scope.json` verifies that only the two layout/scroll product files
differ between probes and both match the PR source. Other product files
differ between the probe base and the PR base. This is an isolated comparison,
not a current-main or production measurement.

## Observations

Input-to-complete-frame milliseconds, including OS, PTY and observer overhead:

| Group | Per build | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Baseline max | Candidate max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| All | 300 | 0.3384165 | 0.273937 | 1.497875 | 0.71475 | 15.425292 | 1.806208 |
| Roster | 180 | 0.311625 | 0.269667 | 1.7115 | 0.729958 | 15.425292 | 1.735875 |
| Info | 120 | 0.3821665 | 0.2780625 | 0.8275 | 0.6485 | 3.054625 | 1.806208 |

Candidate paired medians are lower in all three full sessions, all three
roster groups, and two of three Info groups. Info repetition 2 is worse:
median 0.282458 → 0.372625 ms, p95 0.420708 → 0.702584 ms. The aggregate
improvements do not imply every session or action improved.

The baseline maximum is repetition 3, cycle 3, page up: 15.425292 ms. The
candidate maximum is repetition 1, cycle 5, detail key down: 1.806208 ms.
These outliers are retained without attributing their cause to the change.

Whole-session child CPU is lower in all three pairs: median 0.189669 s for
baseline and 0.171376 s for candidate. It includes startup, navigation, draft
preservation, shutdown and waited descendants, and excludes observer CPU.
It does not isolate CPU time in the changed modules.

## Limits

Every candidate input still exceeds 0.1 ms (minimum 0.176208 ms). This single
three-pair run on a shared CI host supports the observed directional result;
it does not establish a general causal speedup or explain the baseline's long
tail. No observations from other experiments are pooled. The separately
verified static branch removal is not a measurement of dynamic invocations.

This fixture has no live MASC server or model calls. It does not prove physical
display latency, runtime deployment, Keeper continuity, or responsiveness of
all product surfaces. Internal frame reports are retained without assuming
action correlation. P95 is nearest rank `sorted[ceil(0.95*n)-1]`; receipts
allow recomputing every aggregate.
