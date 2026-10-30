# Live Dashboard observation

This follow-up measures the visible Overview rather than extrapolating the
transport microbenchmark to UI performance. It makes no before/after speedup claim.

## Identity and conditions

The live server reported source `b43722cb596bed252b7c4bb626173773550d1438`,
instance `01a160dc-5497-7000-a47b-361987628cc8`. Both ordinary and full health
reported Dashboard source `0ba6e814fe3e4701fa86355055d8e4197e84fdd0` with
`dashboard_surface.status:mismatched`. The full snapshot was ready and 3638ms
old in that check. The mismatch was also visibly displayed in the browser;
it is not inferred solely from zero-transfer resource entries or file age.

These are observations of that served bundle. They cannot establish current
main source behavior or a matching-bundle candidate's performance. The server
was not replaced and its asset directory was not modified for this observation.

## Observations

One visible Overview navigation reported:

| Browser resource/navigation observation | Value |
|---|---:|
| HTML response end | 7.9ms |
| DOM interactive | 20.3ms |
| DOM complete/load event end | 233.3ms |
| First scheduled-automation request duration | 1964.2ms |
| A later scheduled-automation request duration | 29.9ms |
| First goals request duration | 610.8ms |
| First execution request duration | 335.0ms |
| Decoded body of one Keeper tool-call response | 1,370,759 bytes |
| DOM node count at observation | 990 |
| Used JS heap at observation | 11,437,448 bytes |

Resource durations combine client queueing, server processing and transfer.
They do not isolate server CPU, JSON parsing or render time. An initial 1.96s
request followed by a 29.9ms request does not by itself identify a cache defect.
Several tool-call responses appeared in the resource timeline, but no initiating
stack or consumer lifecycle was captured; unnecessary polling is a hypothesis,
not a confirmed diagnosis. No request bodies or response contents were retained.

A separate visible idle observation collected 120 animation-frame intervals:
median 8.3ms, p95 9.2ms, maximum 9.3ms; no long-task entries were observed during
that window. This is idle frame cadence, not input-to-paint latency or evidence
that initial loading never blocks.

## Receipts and next boundary

- [`browser-resources.json`](browser-resources.json): browser resource metrics;
  Keeper path names are replaced with the `:keeper` route placeholder.
- [`browser-idle-frames.json`](browser-idle-frames.json): completed idle window.
- [`browser-server-identity.json`](browser-server-identity.json): selected
  ordinary/full health identity and source-mismatch evidence.
- A screenshot was visually inspected and retained locally for the operator;
  it is not published with runtime content in this source evidence directory.

The next comparable UI measurement needs a Dashboard artifact matching the
selected server source. Artifact preparation is separate from permission to
replace live assets or restart the server. No matching artifact installation,
TUI frame measurement, saturated fanout benchmark, server CPU attribution or
installed performance repair has been completed by this evidence unit.
