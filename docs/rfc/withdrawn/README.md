# Withdrawn RFCs

This directory holds RFCs that were drafted but never implemented or whose
direction was superseded by later work. They are preserved for history —
removed from the active RFC index, but their git blame and contextual
content remain accessible.

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
| 0023 | Kimi Coding API Provider | Provider ships via adapter; spec never ratified |
| 0028 | Bounded Token Prediction | Research idea; never implemented |
| 0030 | masc create CLI | Authoring uses MCP tools + dashboard instead |
| 0031 | Three-Tier Config Disclosure | Env knob work took different direction (RFC-0138/0125) |
| 0040 | Mention dedup at sender | Receive-side dedup (RFC-0090) selected instead |
| 0059 | IDE LSP + Eio Domain/Actor | LSP via RFC-0128; Eio domain never integrated |
| 0061 | Cache-invalidation broadcast envelope | Supplanted by RFC-0138 lock-free architecture |

Future batches (Batch B onward) will follow the same criteria. The active RFC count
will continue to shrink as ghost specs are honestly retired.
