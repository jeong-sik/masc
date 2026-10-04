# Checkpoint history measurement for task-611

The `bench-tests.yml` manual input `compare_checkpoint_history=true` runs the
same valid checkpoint fixture against two verified `linux-x64-probe.yml`
artifacts on one Ubuntu runner. Supply the existing baseline/candidate run,
artifact and full commit inputs. Set other comparison modes to false.
`checkpoint_histories` and `checkpoint_noise` select the fixture sizes; each
requested size must match the session identity and every compared session.
The summary renders those recorded sizes. The runtime-events readers use the
Eio version pinned in `masc.opam.locked`.

For the first task-611 slice (#39761), the source pair is:

- before: `d4baba6e5215604bf512640879c5ebf3844fa3b9`
- after: `a9d0b74116633a42b1e95e991584e65ccc7d71f6`

The default protocol uses three alternating pairs, each with a fresh isolated
workspace, 128 valid v11 checkpoints and 8192 nonmatching files. File contents,
filenames, metadata and request counts match. Each 90-second session issues 90
checkpoint GETs and 90 health GETs at one-second cadence. Each pair of requests
starts from a two-client barrier. This does not establish overlap with the
short directory scan inside the complete inventory handler. Complete inventory
responses must list all valid checkpoints in newest-first order with no errors.

Servers use ephemeral loopback ports, no host credentials, a dead loopback
provider endpoint, disabled autonomy and a paused synthetic Keeper. Actual
binary hashes, embedded source identities, effective roots and zero Keeper
fibers are checked. The server never runs against the operator's workspace.

Both runtime-events consumers acknowledge that backlog draining is complete
before workload admission. Receipts use monotonic durations and wall-clock
intervals; the validator requires every inventory request to lie within both
trace windows. Lost events, missing snapshots, mismatched fixture bytes,
tracer errors or failed process cleanup prevent a summary. SIGINT/SIGTERM
unwinds owned processes; forced runner loss can still interrupt cleanup, and
partial artifacts remain diagnostic evidence only.

Artifacts include the original artifact identities; full HTTP responses;
commands, exit status and server logs; configuration/environment coordinates;
fixture hashes; runner load; scheduler and GC data; runtime-events domain-0
10/50/100ms execution distributions; and cleanup receipts. The parallel existing
`scheduler_lag_probe.sh` is supplemental observation: its substituted HTTP
failure timings are not a correctness gate. Strict HTTP receipts and the
runtime-events validation determine whether the experiment is complete.

`summary.md` reports each pair separately. HTTP latency includes checkpoint
loads, JSON decoding, response encoding and transport. Scheduler percentiles
come from overlapping windows and are not pooled. No performance threshold or
improvement claim is imposed; report regressions or an inconclusive difference.
P95/p99 use nearest rank; with 90 observations, p99 equals the maximum.
The summary states the observation count so that equality is explicit.
Larger fixtures are separate experiments. Choose and record workload sizes
before comparing outcomes; changing inputs cannot retroactively establish an
improvement in the retained 128/8192 experiment.

## Completion scope

This pair measures only checkpoint history scan/filter/sort (#39761). It does
not exercise vision frame/artifact persistence (#39766), cancellation (#39774),
or the remaining arbitrary systhread wrappers/file loops in RFC section 7.5.
It cannot by itself close task-611 or issue #25893.

The original request was stalled on a host coordinate even though GitHub
Actions already supplied a suitable isolated runner. This workflow makes that
execution path concrete; it does not weaken the task's original evidence
contract.

Runtime compatibility and measurement acceptance require the manual experiment
and its retained observations.
