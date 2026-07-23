---
rfc: "0137"
title: "Host FD pressure observation — retired Keeper-pause proposal"
status: Retired
created: 2026-05-19
updated: 2026-07-13
author: jeong-sik
supersedes: []
superseded_by: null
related: ["0097", "0101", "0122"]
implementation_prs: [16665]
---

# RFC-0137 — Host FD pressure observation

## Retirement decision (2026-07-13)

The proposal to translate host FD pressure into automatic Keeper pause or
Docker pre-spawn refusal is retired.

Host FD pressure remains valuable operational evidence, but it is not an
objective permission rule for an individual Keeper action. A single host-level
signal must not stop unrelated Keeper lanes, and the Docker boundary must not
guess whether an operation would fail before asking Docker or the operating
system.

Current behavior is therefore:

- host and process FD probes may record snapshots, transitions, and alerts;
- `Fd_accountant` observes operation lifetimes without delaying them;
- Docker operations return their actual status/output and record real failures;
- no Docker spawn is rejected, serialized, or replayed because a pressure flag
  is active;
- Keeper lifecycle policy, if any, is outside the Docker sandbox boundary and
  must use explicit product-level evidence rather than this retired proposal.

## Historical incident

On 2026-05-19 the macOS host reached severe system-wide FD pressure. The main
holder was Docker Desktop's virtual-machine process rather than the MASC
process. The incident showed two important facts:

1. process-local counters cannot prove host capacity;
2. Docker bind-mount and container lifecycle behavior must be observed directly.

The original proposal connected an out-of-process host-pressure file to
`Keeper_fd_pressure`, then used that state in pre-turn and pre-spawn gates. It
was intended as a temporary safety net while container reuse matured. In
practice, that connection introduced fleet-wide coupling: an observation about
one shared resource could prevent all Keepers from attempting otherwise valid
work.

## Retained components

- Host-pressure polling and metrics may remain as observation.
- Process nofile and open-FD snapshots remain visible to operators.
- Keeper sandbox container reuse remains a structural way to reduce Docker
  mount churn.
- Explicit ENFILE/EMFILE/Docker daemon failures remain logged and attached to
  the operation that experienced them.

## Removed mechanics

- automatic Keeper pause from host FD pressure;
- Docker pre-spawn admission checks;
- pressure-driven spawn serialization;
- static Docker spawn concurrency limits;
- pressure-classified replay of a failed Docker run.

## Verification

- Source search finds no Docker-only throttle module, Docker spawn cap, or
  Docker FD-admission error.
- A pressure observation does not change whether the Docker callback runs.
- A failed Docker run is attempted once, recorded, and returned with its exact
  process status and output.
- FD snapshot and transition telemetry remains readable without being consumed
  as a Docker permission decision.

## Decision history

- 2026-05-19: RFC body and external pressure signal support landed in PR
  #16665 after the host incident.
- 2026-07-13: automatic pause/pre-spawn enforcement was retired; observation
  was retained and the Docker boundary was made nonblocking.

## References

- RFC-0097 — Keeper sandbox container reuse.
- RFC-0101 — observation-only FD accountant.
- PR #16665 — original host-pressure signal implementation.
