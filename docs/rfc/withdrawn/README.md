# Withdrawn RFCs

This directory holds RFCs that were drafted but never implemented or whose
direction was superseded by later work. They are preserved for history —
removed from the active RFC index, but their git blame and contextual
content remain accessible.

> **2026-06-17 cleanup**: withdrawn RFCs with zero live document references
> were deleted from disk (git history retains full content per the policy
> below). Only RFC-0017, RFC-0018, and RFC-0048 remain on disk — kept because
> live documents (`TRACK1-MULTIAGENT-IDE-MVP.md`, `RFC-0042`,
> `observability/dashboard-surface-metrics.md`) still link them. The batch
> tables below remain as the historical withdrawal log, not a disk inventory.

## Why archive instead of delete

- **Authoring trail preserved** — git mv keeps full history without renames cluttering `docs/rfc/` index.
- **Reference resilience** — older commit messages, PR bodies, and memory files may link to these RFCs; archive keeps the file at a discoverable path.
- **No reactivation policy** — Withdrawn RFCs are not eligible for resurrection. New work on the same problem space must open a fresh RFC and may cite the archived one.

## Withdrawal criteria

An RFC enters `withdrawn/` when **all** of the following hold:

1. Status remained Draft for 180+ days
2. No implementation commits in `origin/main` referencing the RFC number
3. Not registered in `docs/rfc/README.md` (active RFC index)
4. Original problem either solved by sibling/successor RFC or organically abandoned

## Frontmatter

Each Withdrawn RFC carries this YAML frontmatter prepended to its body:

```yaml
---
title: <original title>
rfc: NNNN
status: Withdrawn
created: <original date>
withdrawn_date: 2026-05-21
withdrawn_reason: "<why — pointer to successor or abandonment reason>"
---
```

## Batch A — 2026-05-21

First withdrawal batch. 10 RFCs archived after Wave 1 measurement (frontmatter
audit + activity decay + README cross-check):

| RFC | Title | Withdrawn reason summary |
|-----|-------|--------------------------|
| 0013 | IO-wait Sampler | Self-declared deferred; parent plan abandoned |
| 0017 | OCaml ↔ CRDT Boundary | Awareness channel work took different direction |
| 0018 | Compile-time receipt enforcement | Runtime check (Cycle 5) deemed sufficient |
| 0023 | Provider-C Coding API Provider | Provider ships via adapter; spec never ratified |
| 0028 | Bounded Token Prediction | Research idea; never implemented |
| 0030 | masc create CLI | Authoring uses MCP tools + dashboard instead |
| 0031 | Three-Tier Config Disclosure | Env knob work took different direction (RFC-0138/0125) |
| 0040 | Mention dedup at sender | Receive-side dedup (RFC-0090) selected instead |
| 0059 | IDE LSP + Eio Domain/Actor | LSP via RFC-0128; Eio domain never integrated |
| 0061 | Cache-invalidation broadcast envelope | Supplanted by RFC-0138 lock-free architecture |

## Batch B — 2026-05-21

Second withdrawal batch. 4 RFCs archived after body-level inspection identified
explicit `superseded_by` relationships. The original 8-candidate pool was
narrowed to 4 because body inspection revealed:

- RFC-0005 still had open Phase 2-4 at that time; those policy phases were
  withdrawn on 2026-07-13 while the objective typed-IR work remained usable.
- RFC-0008 has merged PR-1 (#10660) and RFC-0019 reconciliation (partial impl)
- RFC-0019 is currently active (credential SSOT work in agent_delegation scope)

| RFC | Title | superseded_by | Withdrawn reason summary |
|-----|-------|---------------|--------------------------|
| 0039 | Keeper Turn FSM streaming escape | RFC-0072 | Absorbed by 5-axis composite sub-FSM observer (KSM/KTC/KDP/KMC/KCL) |
| 0048 | Dashboard IA Phase 2 | RFC-0135 | Typed snapshot architecture supplanted IA approach (25+ commits) |
| 0055 | Runtime Fallback Chain Capability-Tier Routing | RFC-0058 | Self-declared superseded; §1 Supersedes ledger absorbed concern |
| 0066 | Legacy *_models Catalog Purge | RFC-0058 | Self-positioned as closeout phase of RFC-0058 declarative runtime |

Future batches will continue the same criteria + body inspection requirement.
The active RFC count continues to shrink as ghost specs are honestly retired.

## Batch C (annex from Phase 3a sweep) — 2026-05-21

Third withdrawal — incidental finding during Phase 3a Active sweep
(commits 1-4 frontmatter normalization). Body inspection revealed
one RFC self-declared as retired.

| RFC | Title | Withdrawn reason |
|-----|-------|------------------|
| 0026 | Retired MASC Admission Router (originally Work-Conserving Keeper Admission) | Body self-declares "retired" — MASC-side provider/model admission router has been removed. File/slug name diverged from content. |

Note: original slug `work-conserving-keeper-admission` no longer reflects
current state; body title was updated to "Retired MASC Admission Router"
at some past point. File renamed via git mv to withdrawn/ preserves blame.

Future batches will continue. The active RFC count continues to shrink
as ghost specs are honestly retired.

## Architecture withdrawal — 2026-07-13

The Keeper boundary hard cut withdrew a connected family of RFCs without the
180-day aging requirement. These documents were actively dangerous because
they still instructed implementers to recreate policy removed from runtime.
Their original filenames remain as short tombstones so existing links resolve;
git history retains the full proposals.

| RFC | Retired direction |
|---|---|
| 0005, 0054 | executable-name and command-class authorization substrate and its generator |
| 0194 | typed tool semantics used as an authorization SSOT |
| 0199, 0222, 0224 | deterministic evidence/checklist-owned Task completion |
| 0234 | Scheduler-owned effect classes and separate-principal approval |
| 0239 | no-progress streak pause and semantic wake suppression |
| 0262 | hierarchical Task-completion authority |
| 0273 | policy tiers and hidden tool access in dashboard configuration |
| 0284 | deleted command-semantics and parallel guidance-visibility guard |
| 0293 | execution-backend properties converted into policy ranks |
| 0304 | Critical-class and timer-derived HITL escalation |
| 0308, 0311, 0323, 0337 | verifier/evidence floors above LLM Task judgment |
| 0322 | repository catalog membership used as read authorization |
| 0331 | tool-registration effect class used as authorization |
| typed-egress-resource-capability | vendor host/method/path classification in generic egress |

The replacement boundary is exact Always Allowed, configured LLM Auto Judge,
or non-blocking HITL at the product-neutral Keeper Gate. Typed input, path jail,
sandbox containment, and explicit execution failures remain objective
invariants rather than authorization ranks.
