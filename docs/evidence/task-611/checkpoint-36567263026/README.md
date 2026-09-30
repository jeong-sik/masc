# Task-611 checkpoint comparison: measured, improvement not established

[CI run 36567263026](https://github.com/jeong-sik/masc/actions/runs/36567263026)
completed successfully on 2026-09-29 12:29:22 UTC. The harness revision was
`d0bfa2b60dfa4087130540dcd7564e953094c15b` in PR #39974.

This executes rondo's checkpoint measurement plan for #39761, using identical
128-checkpoint/8192-nonmatching-file fixtures on one GitHub Ubuntu runner.
There are three alternating pairs of 90-second sessions, each with 90 inventory
requests and 90 paired health requests. All six sessions passed fixture,
embedded binary identity, complete trace-window coverage, zero lost events and
owned-process cleanup validation. The downloaded artifact was independently
revalidated with the committed `validate` function.

## What the results establish

The experiment is complete; an improvement under this workload is not established.

- Inventory median: before 26.034–26.755 ms; after 26.310–27.062 ms.
- Scheduler p99: before 0.190–0.214 ms; after 0.183–0.235 ms.
- Main-domain uninterrupted runs >=10, >=50, and >=100 ms: zero in every session.
- Main-domain maximum uninterrupted execution: before 2.4–3.1 ms; after 3.5–3.9 ms.

No baseline stall was reproduced. The endpoint includes loads/decoding and JSON
response work beyond the changed scan. These small samples and varying host
load do not justify a causal improvement or regression claim. See the
[per-pair table](summary.md) and raw traces; do not pool overlapping scheduler
windows or interpret successful execution as performance acceptance.

## Provenance and retained evidence

- Before source: `d4baba6e5215604bf512640879c5ebf3844fa3b9`, probe run
  `36565596287`, artifact `11032430026`.
- After source: `a9d0b74116633a42b1e95e991584e65ccc7d71f6`, probe run
  `36565600490`, artifact `11031574873`.
- Comparison artifact: `11032508434`, original ZIP SHA-256
  `668c3c95ee207aa2ea16c644fef5fcacfb90e2a737b81b5c58b925e1c25c8283`.
- Every session fixture SHA-256:
  `8bf1b86c79b38555c9576c5cfbd5870f9bb52318757d3f34923073831a9ef1e5`.

`raw-evidence.tar.gz` preserves every downloaded raw file so evidence survives
Actions artifact expiration: complete requests/responses, tool commands,
stdout/stderr/exit receipts, server logs, configs/environment coordinates,
fixture manifests, scheduler/GC observations, rtev distributions and cleanup.
It repackages the downloaded directory; its checksum is intentionally different
from the original Actions ZIP. `SHA256SUMS` covers this archive and copied
machine-readable result files. All data came from isolated synthetic workspaces.

## Remaining task contract

The comparison is limited to #39761. It does not measure vision persistence
(#39766), cancellation (#39774), or resolve the remaining file-loop and arbitrary
systhread-wrapper inventory in RFC-main-domain-scheduler-latency section 7.5.
The original task requires implementation, full before/after evidence, and
closing issue #25893. This result is one piece of evidence, not task completion.

The failed first run `36566947737` is excluded: its fixture encoded cost as JSON
integer 0, which v11 rejected. The current run fixes that to float 0.0 and adds a
regression check. The original failed run still retained clean process-exit
receipts; it supplies no performance measurements.
