# Canonical Architecture Cleanup RFC

**Status**: Draft
**Date**: 2026-04-09
**Scope**: Canonical architecture truth, boundary enforcement, and surface reduction
**One sentence**: Keep the repo-coordination + keeper-runtime spine, and delete, hide, or extract the rest until docs, code, and public surface tell the same story.

## Related Documents

- `../PRODUCT-REVIEW.md`
- `../MCP-SURFACE-AUDIT.md`
- `../ARCHITECTURE-COMPLEXITY-ANALYSIS.md`
- `../spec/SPEC-INDEX.md`
- `../spec/01-system-overview.md`
- `../spec/C-implementation-status.md`
- `../architecture-boundary.md`

## Problem Statement

`masc-mcp` has a credible core design:

- repo-local coordination for multiple coding agents
- OAS-backed keeper runtime for long-running execution

The problem is not that the repo lacks an architecture. The problem is that the
repo currently presents multiple incompatible truths about that architecture.

This creates three concrete failures:

1. readers cannot tell which path is actually canonical
2. implementers cannot trust the stated module boundary rules
3. public MCP surface claims drift from the real front-door promise

The current cleanup goal is therefore not "invent a new architecture". It is:

- converge on one canonical product story
- delete or hide surfaces already treated as retired or non-canonical
- enforce the MASC/OAS boundary in code rather than prose

## Canonical Decision

The canonical front door is:

- repo coordination: project scope, task ownership, worktree hygiene, heartbeat
- keeper runtime: OAS-backed keeper lifecycle and diagnostics

Everything else must be classified explicitly as one of:

- advanced workflow
- compatibility lane
- experimental surface
- removed / retired surface

The repo must stop describing non-canonical surfaces as equally first-class.

## Evidence

| ID | Symptom | Current evidence | Why this is a problem |
|----|---------|------------------|------------------------|
| E1 | Front-door promise is narrow, but public inventory claims are wide | `README.md` describes repo coordination + keeper runtime as the front door, while `docs/MCP-SURFACE-AUDIT.md` says default `tools/list` exposes 403 visible schemas | Users and agents cannot infer the intended default surface from docs alone |
| E2 | Chain plane is described as canonical after the chain engine was removed | `docs/spec/01-system-overview.md`, `docs/MERGED-ARCHITECTURE-SSOT.md`, and `docs/spec/04-chain-engine.md` still present a native chain plane, while `docs/spec/C-implementation-status.md` says Chain Engine is removed and the codebase no longer contains `lib/chain_*` | The orchestration spine is internally contradictory |
| E3 | MASC/OAS boundary is declared as strict but not enforced | `docs/architecture-boundary.md` forbids `Agent_sdk` imports in MASC core, but real imports exist outside keeper/worker/bridge lanes | Boundary rules become advisory and regress silently |
| E4 | "Small front door" narrative sits on top of a platform-scale monolith | `docs/ARCHITECTURE-COMPLEXITY-ANALYSIS.md` and `docs/spec/SPEC-INDEX.md` both show a very large tool/module footprint, while top-level docs increasingly describe a much smaller product | Without reduction or extraction, the product explanation remains fragile |

## Cleanup Matrix

| Group | Decision | Action |
|------|----------|--------|
| Front-door docs and audits | Rewrite | Align README, surface audit, and spec text to the same public story and the same counting method |
| Removed chain narrative | Delete / rewrite | Delete removed-chain claims, downgrade historical chain docs, and stop presenting chain DSL as current canonical substrate |
| Compatibility and experimental public references | Hide / extract / delete | Keep only what still has an explicit support story; hide or extract the rest from default discovery |
| Non-bridge `Agent_sdk` imports outside keeper/worker lanes | Rewrite / enforce | Move translation logic into bridge modules or explicitly reclassify modules, then add CI enforcement |
| Historical SSOT docs that still read as current truth | Downgrade | Mark as historical snapshots or superseded references, not active architecture SSOT |

## Delete Candidates

These are candidates for deletion or hard downgrade, not preservation-by-default:

- docs that still describe removed chain functionality as current canonical behavior
- stale surface-audit claims that contradict `Tool_catalog.public_mcp_tools`
- non-canonical public narrative around experimental/game/research surfaces
- boundary documents that over-promise strictness without a verification gate

The default policy for surfaces already documented as removed, retired, or
non-canonical is deletion or hiding, not indefinite preservation.

## Sequenced Tracks

### Track A: Docs truth convergence

- pick one counting source for public MCP truth and use it everywhere
- rewrite front-door docs around repo coordination + keeper runtime
- downgrade chain and compatibility material from "canonical" to "historical" or "advanced"
- ensure removed surfaces are described as removed, not merely optional

### Track B: OAS boundary enforcement

- define the allowed `Agent_sdk` import lanes as code, not prose only
- move non-keeper/non-worker translation logic into dedicated bridge modules where justified
- fail CI when new non-bridge boundary violations are introduced
- stop claiming "perfect compliance" until the grep and classification rules actually pass

### Track C: Surface reduction and extraction

- reduce default discovery to the actual public MCP contract
- classify each non-front-door surface as advanced, compatibility, experimental, or removed
- hide, extract, or delete experimental/game/research surfaces that do not belong in the default product story
- keep only the minimal compatibility surface required for real callers

## Non-Goals

- redesigning the coordination model from scratch
- replacing OAS with a MASC-native execution engine
- same-PR deletion of all non-canonical code paths
- speculative new platform capabilities

This RFC is about cleanup and truth convergence, not expansion.

## Exit Criteria

The cleanup is complete only when all of the following are true:

- repo docs present one canonical front door and one consistent public surface story
- removed chain behavior is no longer documented as current canonical architecture
- the MASC/OAS boundary is enforced by an executable check, not just a document
- default public discovery matches the documented public MCP surface
- experimental or compatibility surfaces are explicitly hidden, extracted, or clearly marked as non-canonical

## Implementation Defaults

- prefer deletion over indefinite historical clutter when the repo already treats a surface as removed
- prefer hiding over documenting an experimental surface as first-class
- prefer extraction over keeping unrelated experimental domains in the default product narrative
- prefer CI-enforced boundary rules over reviewer memory

## Follow-On Issues

This RFC should be tracked by:

- umbrella: #6131 Canonical architecture cleanup: truth, boundary, and surface reduction
- docs truth convergence: #6128
- boundary enforcement: #6129
- surface reduction and extraction: #6130
