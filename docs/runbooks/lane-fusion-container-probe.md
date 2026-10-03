# Isolated Fusion container qualification

The manual `linux-x64-probe.yml` target `lane-fusion-container` builds an exact-head
native qualification executable and both declared worker images on the CI daemon.
It starts the real Lane runtime in a fresh workspace. Provider responses come
from loopback HTTP fixtures, with no live provider credentials or production
Keeper activity.

```sh
gh workflow run linux-x64-probe.yml --repo jeong-sik/masc \
  --ref <branch-containing-the-probe> -f target=lane-fusion-container
```

Run this at a work-unit finishing boundary. Follow the repository execution
protocol: do not build Dune or Docker locally and do not watch/poll CI in a loop.
A dispatched or queued run is not evidence that the qualification executed.

The intended scenario is:

```text
one retained snapshot ── panel A ──┐
                     └─ panel B ──┴── judge ── report ── local Broadcast artifact
```

All four workers use actual Docker and the production runtime backend. Model
access uses the server's installed host sampling factory. A shared HTTP barrier
holds both panel responses until both requests arrive, so overlap is demonstrated
by protocol events rather than elapsed-time thresholds. Judge input selection and
row namespacing are performed by the real runtime's named-output source adapter.
All four workers are installed in one reconciliation. Judge waits for its input
ports, and automatic refreshes compare completed input identities so overlapping
producer notifications cannot resample an identical captured generation. The
native composition scenario additionally forces this acquisition/notification
overlap with a barrier and checks explicit reruns and new generations separately.

The probe checks:

- The embedded binary commit and mounted package checkout match the requested
  head. The workflow records binary SHA-256 and built image identities.
- Actual container inspection reports network mode `none`, a read-only root,
  dropped capabilities, no privilege escalation, the unprivileged image user,
  read-only package mounts, exact worker ownership, and no added host environment.
- Model requests are retained before HTTP invocation; input, output controls,
  actual fixture model identities and both panel answers survive the full chain.
- The report freezes to the Keeper artifact store. An explicit Broadcast commits
  only to this fresh local fixture workspace; its receipt is checked against the
  actual durable message. The probe supplies explicit operator authority and a
  stable publication request ID, and registers the same production Fleet
  backend as server startup. Its Keeper registry is empty; this verifies local
  commit, not recipient delivery or retry recovery. Artifact reading is separate
  from actual Keeper use.
- Exact owned containers are removed and absence is checked against a responsive
  daemon. Published source/model/report artifacts remain readable after Detach
  and removal of the Lane store.

The probe's finite observation deadline applies only to this qualification. It
does not add a timeout or budget gate to a Keeper, model route, or installed Lane.
Probe-owned Docker setup, inspection and cleanup calls also have finite control
deadlines and reap their child processes. Daemon/image absence and failed cleanup
are failures, not skipped success.

The workflow uploads the `lane-fusion-container-<sha>-attempt-<n>` bundle, including
failure evidence where available. Read `evidence/summary.json`, the final runtime
snapshot, HTTP request receipts, container inspection receipts, report row,
Broadcast receipt, Keeper artifact manifest and preserved artifact bytes. A
summary from another head cannot qualify the current checkout.

Even a successful run proves only the stated real-container/host-transport
scenario with synthetic HTTP model replies. It does not prove live provider
inference, official-client sampling support, installed TUI rendering, actual
Keeper reading/decision use, or the full product goal.

## Waiting input and evidence propagation

An installed Judge can start before its upstream workers have completed. The
computation package returns empty rows and explicit incomplete input coverage
while declared inputs have no observations; it does not sample empty substitutes
or call this a failed model response. Malformed or foreign-analysis inputs are
still rejected.

Each Judge propagates upstream model references and digest-backed row evidence
into its own structured evidence set. URI-only citations remain in the untrusted
input context; they are not promoted to retained publication references. Keeper publication traverses those structured references
without parsing arbitrary referenced source bodies. This keeps panel requests,
outcomes and original input snapshots available when a final report is frozen.

For `source_changes` packages, automatic Lane-output notifications are refresh
hints. Identity includes the producer instance, generation, output selection,
configuration revision, status, coverage and output bytes. Only the host's outer
Lane-port acquisition timestamp is excluded. File snapshot bytes remain exact;
live machine/browser/Fusion captures retain their existing notification behavior.
Explicit Observe always calls the package even when input identity is unchanged.
