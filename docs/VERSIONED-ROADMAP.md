# masc-mcp Versioned Roadmap — Feature Trains First

> Last updated: 2026-03-13
> Baseline: v2.86.0

## Why This Document Exists

`masc-mcp` has enough internal surface area that "stability work" can easily drift away from a clear release promise.
This roadmap keeps release planning anchored to one rule:

**Each minor release must ship a user-visible capability promise.**

Internal hardening still matters, but it should land as part of a named feature train instead of as an unbounded backlog.

## Versioning Rules

These version layers are separate and should not be mixed:

| Layer | Meaning | When it changes | Source |
|------|---------|-----------------|--------|
| Release SemVer | Product release train | Every patch/minor/major release | `dune-project`, `README.md`, `CHANGELOG.md` |
| Protocol version | Public MCP contract compatibility | Only when public MCP contract changes | `/health.protocol`, `mcp-protocol-version` |
| Artifact schema version | Report/proof/checkpoint payload format | Only when stored payload shape changes | report/proof/checkpoint schema |

Release lane rules:

- `2.x.0`: feature train release. A minor must have one primary promise.
- `2.x.1+`: patch stabilization for the current train only.
- Public MCP surface expansion belongs in `minor` or `major`, not in patch.
- Migration-heavy cleanup belongs in a named train, not in a stabilization patch.

Cross-check: `scripts/bump-version.sh` already treats these as distinct layers.

## Intake and Triage

The user remains the primary dogfooding reporter, but Codex and internal agents are also allowed to file issues when they observe a concrete problem.
Agent-filed reports should follow the same evidence standard as human-filed reports.
To keep reports actionable, intake is split into three buckets:

| Type | Use for | Default routing |
|------|---------|-----------------|
| `type:bug` | Broken behavior, regression, data loss, incorrect result | Current patch or current train blocker |
| `type:friction` | Usable but annoying, confusing, too slow, sharp UX edge | Current patch if small, next minor if workflow redesign |
| `type:feature` | New capability, new workflow, new public surface | Next unopened minor train |

Release labeling rules:

- Every issue gets exactly one `target:*` label.
- `release-blocker` means the issue must be closed before the tagged release.
- Legacy labels such as `bug` or `enhancement` may remain, but `type:*` and `target:*` are the planning SSOT going forward.
- Agent-filed reports should include reproducible evidence, a concrete symptom, and the smallest plausible target train.

## Source Documents

This roadmap is a priority-ordered view over the existing planning docs.
The detailed design documents remain the implementation references.

| Source document | Role in this roadmap |
|-----------------|----------------------|
| `docs/RELEASE-ROADMAP.md` | Patch stabilization policy for `v2.86.1` |
| `docs/IMPROVEMENT-PLAN-2026-01.md` | Swarm reliability and recovery improvements |
| `docs/IMMORTAL-SERVER-ROADMAP.md` | Server HA and self-healing follow-up |

## Milestone 1: v2.86.1 — Green Main

**Release promise**: main is releasable again.

This is the only active patch lane right now.
It is not a feature release.

Includes:

- CI failure fixes on `main`
- release metadata cleanup
- changelog completion
- worktree cleanup that reduces operational drag
- compatibility fixes that do not widen the public contract

Stays out:

- new public MCP tools or schemas
- dashboard IA redesign
- migration-heavy alias cleanup
- future-train feature work

Exit criteria:

- required CI on `main` is green
- `CHANGELOG.md` has no `TBD` entries for `2.86.0` and `2.86.1`
- worktree count is back to an operational baseline

## Milestone 2: v2.87.0 — Reliable Swarm

**Release promise**: a live swarm keeps progressing when one runtime path fails.

This train turns the most urgent Swarm fragility into explicit product behavior.

Includes:

- provider fallback chain for live harness execution
- approval timeout with explicit auto-deny behavior
- dispatch tick serialization to prevent state corruption
- artifact content validation instead of file-exists-only checks

User-visible effect:

- one provider outage should not collapse the whole swarm run
- approval deadlocks should resolve into an explicit failure state
- concurrent dispatch should fail safely, not corrupt state
- broken artifacts should fail loudly

Exit criteria:

- provider-down scenario falls back and completes with proof
- approval timeout emits auto-deny and broadcast evidence
- concurrent tick race is serialized with one rejected attempt
- malformed artifact fails with an explicit error

## Milestone 3: v2.88.0 — Visible Swarm

**Release promise**: operators can see swarm health before failure becomes silent.

Includes:

- heartbeat latency and drift tracking
- zombie agent detection and automatic retire
- final marker warning and assisted-marker accounting
- dashboard health surfacing for agent heartbeat state
- Swarm coverage gate in CI

User-visible effect:

- unhealthy agents become diagnosable from the dashboard and logs
- missing or assisted final markers are visible instead of silently blending into success

Exit criteria:

- zombie agent detection is test-proven
- marker anomalies are broadcast and summarized
- coverage report is produced in CI for Swarm-critical modules

## Milestone 4: v2.89.0 — Recoverable Swarm

**Release promise**: long-running swarm work can resume instead of restarting from zero.

Includes:

- automatic checkpointing
- schema-based message validation
- Lamport timestamps for ordering-sensitive analysis
- keeper timeout persistence across restart

User-visible effect:

- restart and recovery become part of the supported workflow
- malformed messages fail as contract errors, not vague runtime drift
- message ordering bugs become diagnosable

Exit criteria:

- crash and restart can resume from checkpoint
- schema-invalid messages fail with explicit contract errors
- ordering inversions are detected and reported

## Milestone 5: v2.90.0 — Immortal Base

**Release promise**: the server survives component failure and shuts down cleanly.

Includes:

- supervision tree
- health check system
- graceful shutdown
- first-pass recovery hooks for critical children

Exit criteria:

- `/health` reports component-level state
- `SIGTERM` drains active work instead of dropping it
- supervised child crash triggers controlled restart behavior

## Milestone 6: v2.91.0 — Product Portfolio Trim

**Release promise**: experimental surfaces have explicit keep, graduate, or archive decisions.

Includes:

- category review for TRPG, Voice, Autoresearch, MDAL, and RISC
- explicit graduation criteria for Tier 2 promotion
- archive decisions for stale or unowned surfaces

Exit criteria:

- each experimental category has a written keep / graduate / archive decision
- deprecated or archived surfaces are reflected in docs and labels

## Milestone 7: v2.92.0+ — Immortal P2

**Release promise**: recovery becomes automatic instead of merely supervised.

Includes:

- exponential-backoff auto recovery
- circuit breaker state machine
- persistent state restore for restart paths
- follow-up architecture moves such as board storage migration when justified

## Release Summary

| Version | Train | Primary promise |
|---------|-------|-----------------|
| `v2.86.1` | Green Main | main is releasable again |
| `v2.87.0` | Reliable Swarm | Swarm keeps going when one runtime path fails |
| `v2.88.0` | Visible Swarm | Swarm health becomes visible before silent failure |
| `v2.89.0` | Recoverable Swarm | Swarm work can resume after interruption |
| `v2.90.0` | Immortal Base | server survives component failure cleanly |
| `v2.91.0` | Product Portfolio Trim | experimental surfaces get explicit decisions |
| `v2.92.0+` | Immortal P2 | recovery becomes automatic and persistent |

## Planning Rules to Keep

- Do not open a new train without naming the user-visible promise first.
- Do not pull future-train work into the active patch lane.
- Do not treat `friction` as "not a bug, ignore it"; small friction belongs in patch, repeated friction becomes the next train.
- Tag releases only after the train exit criteria are evidenced, not merely asserted.
