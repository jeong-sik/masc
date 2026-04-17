---
status: reference
last_verified: 2026-04-17
code_refs:
  - ROADMAP.md
  - dune-project
  - CHANGELOG.md
---

# masc-mcp Versioned Roadmap — Feature Trains First

> Last updated: 2026-04-09
> Baseline: v0.2.0

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

- `0.y.0`: feature train release. Each train must have one primary promise.
- `0.y.z` where `z > 0`: stabilization for the current train only.
- `1.0.0` is reserved for the point where repo coordination, release truth, and the core operator path are trustworthy without caveats.
- Public MCP surface expansion belongs in `minor` or `major`, not in patch.
- Migration-heavy cleanup belongs in a named train, not in a stabilization patch.
- Release automation compares tags inside the active major series only, so frozen legacy `v2.*` tags do not block the `0.x` line.

Cross-check: `scripts/bump-version.sh` already treats these as distinct layers.

Current numbering note:

- `v2.87.0` through `v2.263.0` remain immutable historical tags from the old internal release-train counter.
- `v0.2.0` resets product SemVer to the honest pre-1.0 line.
- Historical `v0.1.0` and `v0.1.1` tags already exist, so the active reset starts at the next unused train.
- No new `v2.*` release tags should be published.

Bootstrap sequence after the reset:

1. merge the `v0.2.0` reset PR
2. publish tag `v0.2.0`
3. only then open `0.3.0` or later train bumps

The release-train guard warns while `0.2.0` is merged but untagged, and it fails any attempt
to widen the `0.x` train before that pending tag is published.

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
- Agent-filed reports should include reproducible evidence, a concrete symptom, and the smallest plausible planning lane.
- Blank issues stay disabled so intake goes through a typed issue form by default.
- Current issue forms collect a planning area plus `target:now|next|later`, and automation adds `triage-required`
  until the issue has exactly one `type:*`, one `area:*`, and one `target:*` label.
- `triage-required` means the issue is not in the execution queue yet. Ownership,
  duplicate handling, and exact release placement must be resolved before work starts.

## Source Documents

This roadmap is a priority-ordered view over the existing planning docs.
The detailed design documents remain the implementation references.

| Source document | Role in this roadmap |
|-----------------|----------------------|
| `docs/archive/RELEASE-ROADMAP-v287.md` | Patch stabilization policy that led into the `v2.87.0` closeout lane |
| `docs/IMMORTAL-SERVER-ROADMAP.md` | Server HA and self-healing follow-up |

## Milestone 1: v2.87.0 — Release Closeout

**Release promise**: the merged `v2.87.0` release story is internally consistent again.

This is a bookkeeping closeout lane, not a new feature train.
Tracking issue: `#1017 v2.87.0 closeout: release bookkeeping`

Includes:

- restore required `main` CI to green after the merged `v2.87.0` bump
- replace top-level `CHANGELOG.md` `TBD` placeholders with actual merged release notes
- reduce `masc-mcp` worktree count to an operational baseline or explicitly track the remainder

Stays out:

- new feature-train work that belongs in `v2.88.0+`
- public MCP surface expansion
- migration-heavy cleanup unrelated to release honesty

Exit criteria:

- required CI on `main` is green
- `CHANGELOG.md` has no `TBD` entries for `2.86.0` and `2.87.0`
- worktree inventory is reduced or the remainder is explicitly tracked

## Milestone 2: v2.88.0 — Reliable Swarm

**Release promise**: a live swarm keeps progressing when one runtime path fails.

This train turns the most urgent Swarm fragility into explicit product behavior.
Tracking issue: `#1008 v2.88.0 closeout: Reliable Swarm`

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

## Milestone 3: v2.89.0 — Visible Swarm

**Release promise**: operators can see swarm health before failure becomes silent.
Tracking issue: `#1009 v2.89.0 closeout: Visible Swarm`

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

## Milestone 4: v2.90.0 — Recoverable Swarm

**Release promise**: long-running swarm work can resume instead of restarting from zero.
Tracking issue: `#1010 v2.90.0 closeout: Recoverable Swarm`

Includes:

- automatic checkpointing
- schema-based message validation
- keeper timeout persistence across restart

User-visible effect:

- restart and recovery become part of the supported workflow
- malformed messages fail as contract errors, not vague runtime drift
- message ordering bugs become diagnosable

Exit criteria:

- crash and restart can resume from checkpoint
- schema-invalid messages fail with explicit contract errors
- ordering inversions are detected and reported

## Milestone 5: v2.91.0 — Immortal Base

**Release promise**: the server survives component failure and shuts down cleanly.
Tracking issue: `#1011 v2.91.0 closeout: Immortal Base`

Includes:

- supervision tree
- health check system
- graceful shutdown
- first-pass recovery hooks for critical children

Exit criteria:

- `/health` reports component-level state
- `SIGTERM` drains active work instead of dropping it
- supervised child crash triggers controlled restart behavior

## Milestone 6: v2.92.0 — Product Portfolio Trim

**Release promise**: experimental surfaces have explicit keep, graduate, or archive decisions.
Tracking issue: `#1012 v2.92.0 closeout: Product Portfolio Trim`

Includes:

- category review for TRPG, Voice, Autoresearch, MDAL, and RISC
- explicit graduation criteria for Tier 2 promotion
- archive decisions for stale or unowned surfaces

Exit criteria:

- each experimental category has a written keep / graduate / archive decision
- deprecated or archived surfaces are reflected in docs and labels

## Milestone 7: v2.93.0+ — Immortal P2

**Release promise**: recovery becomes automatic instead of merely supervised.
Tracking issue: `#1013 v2.93.0+ closeout: Immortal P2`

Includes:

- exponential-backoff auto recovery
- circuit breaker state machine
- persistent state restore for restart paths
- follow-up architecture moves such as board storage migration when justified

## Release Summary

| Version | Train | Primary promise |
|---------|-------|-----------------|
| `v2.87.0` | Release Closeout | release bookkeeping, CI, changelog, and worktree story are honest again |
| `v2.88.0` | Reliable Swarm | Swarm keeps going when one runtime path fails |
| `v2.89.0` | Visible Swarm | Swarm health becomes visible before silent failure |
| `v2.90.0` | Recoverable Swarm | Swarm work can resume after interruption |
| `v2.91.0` | Immortal Base | server survives component failure cleanly |
| `v2.92.0` | Product Portfolio Trim | experimental surfaces get explicit decisions |
| `v2.93.0+` | Immortal P2 | recovery becomes automatic and persistent |

## Planning Rules to Keep

- Do not open a new train without naming the user-visible promise first.
- Do not pull future-train work into the active patch lane.
- Do not treat `friction` as "not a bug, ignore it"; small friction belongs in patch, repeated friction becomes the next train.
- Tag releases only after the train exit criteria are evidenced, not merely asserted.
