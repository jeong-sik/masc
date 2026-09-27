# Completed agenda comparison retry

[Run 36257181447](https://github.com/jeong-sik/masc/actions/runs/36257181447)
completed three alternating pairs (AB, BA, AB): 600 acknowledged input frames
and six draft-preservation checks. This fresh run is kept separate from the
[incomplete first attempt](../failed-comparison-36256591061/README.md). None of
that attempt's observations enter the aggregates here.

## Identity and protocol

- Baseline: `0278eac5a67d8ec9da06337cae781d96ad702b68`, build run
  `36254942697`, artifact `10910511317`.
- Candidate: `56884cdc2d82d8b4b3f9b64597c6e770228e9712`, build run
  `36255838724`, artifact `10911156552`.
- Observer: `304f5f6f67edcb38e3b2ad5da6759d64f73a4983`.
- Comparison artifact: `10911239266`; original ZIP SHA-256
  `c8109e5be4b0f80c7fcf4c0fc236fc7c95826b8fd96fd5f4d3d2bf5c015b5c50`.
- Each session uses ten cycles of six roster actions and four Info actions,
  250 retained Channels bindings plus one other Keeper, and waits for the
  expected viewport and frame-end acknowledgement before sending another input.

`raw/` retains all 27 artifact members, including full observations, stdout,
stderr, internal frame reports, identities and comparison summary. Only the
runner checkout path was replaced by `<CI_CHECKOUT>`; `redaction.json` records
both original and published hashes. `source-scope.json` verifies that only the
three agenda product files differ between probes, and that the implementation,
interface, regression test and changed state-projection region match the PR.
Other source differences between the probe base and PR base remain outside
this isolated comparison.

## Observations

Input-to-complete-frame milliseconds, including PTY, OS and observer overhead:

| Group | Per build | Baseline median | Candidate median | Baseline p95 | Candidate p95 | Baseline max | Candidate max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| All | 300 | 0.4552295 | 0.432229 | 1.047834 | 0.838542 | 1.857 | 2.596667 |
| Roster | 180 | 0.5158125 | 0.443604 | 1.144292 | 0.8675 | 1.857 | 2.596667 |
| Info | 120 | 0.3920625 | 0.4059375 | 0.880625 | 0.722167 | 1.431791 | 2.250542 |

The candidate's paired median is lower in two of three complete sessions,
three of three roster groups, and one of three Info groups. Roster median and
p95 are lower in this run; Info median and both groups' maxima are higher.
The largest candidate observation is repetition 2, cycle 3, page up:
2.596667 ms. The baseline maximum is repetition 3, cycle 4, arrow up: 1.857 ms.

Whole-session child CPU is lower in all three pairs; the median is 0.200976 s
for baseline and 0.183021 s for candidate. This includes startup, navigation,
draft preservation, shutdown and waited descendants. It is not agenda-only
CPU time and excludes observer CPU.

## Limits

All 300 candidate observations exceed 0.1 ms (minimum 0.213667 ms). Three
pairs on a shared CI host do not establish a general causal latency benefit.
This is a synthetic fixture with no live server or model calls; it does not
measure physical display latency, production Keeper continuity, deployment,
or agenda-overlay interaction. Internal frame reports are retained but are
not action-correlated measurements. P95 uses nearest rank
`sorted[ceil(0.95*n)-1]`; all aggregates can be recomputed from the receipts.
