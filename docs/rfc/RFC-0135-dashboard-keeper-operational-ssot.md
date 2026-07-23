---
rfc: "0135"
title: "Supersede dashboard-derived Keeper disposition"
status: Superseded
created: 2026-05-19
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0068"]
implementation_prs: []
---

# RFC-0135 — Supersede dashboard-derived Keeper disposition

The useful SSOT requirement survives: one backend observation must not render
as conflicting facts on different dashboard surfaces. The old implementation
is superseded because it combined lifecycle, resource, completion, and failure
signals into `blocked`, `stuck`, automatic-pause, and attention hierarchies.

Current dashboard projections preserve the source observation, Keeper/lane
identity, correlation id, time, and provenance. They may format those facts but
must not infer authorization, risk, terminal state, or operator action.
Lifecycle state changes only through explicit operator control or a durable
Dead tombstone.

This document is historical only and defines no compatibility contract.
