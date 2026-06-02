---
title: Descriptor-Owned Tool Surface
rfc: 0064
status: Superseded
created: 2026-05-11
implementation_prs: []
collision_note: "RFC-0064 number is used by two files (this + RFC-0064-capacity-probe-adapter.md). One must be renumbered in a separate cleanup."
---

# RFC-0064: Descriptor-Owned Tool Surface

This RFC used to describe a two-surface alias router. That design has been
superseded by the descriptor-owned tool surface.

Current implementation guidance:

- `Agent_tool_descriptor` is the source of truth for public names, internal
  handlers, input schema, policy projection, runtime handler selection, and
  receipt labels.
- The active model-facing tool names are `Execute`, `SearchFiles`, `ReadFile`,
  `EditFile`, `WriteFile`, `SearchWeb`, and `FetchWeb`.
- Retired provider built-in aliases are routing misses.
- Internal handler names are implementation details and must not be taught as a
  model-facing surface.
- Result/evidence telemetry should record descriptor route evidence rather than
  an alias-canonicalization event.

Do not add new alias-router tiers, hallucinated-tool string classifiers, or
public-name compatibility tables here.
