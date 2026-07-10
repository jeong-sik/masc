---
rfc: "0294"
title: "Remove workspace Goal horizon"
status: Implemented
created: 2026-06-24
updated: 2026-07-10
author: jeong-sik
supersedes: ["0288"]
superseded_by: "KEEPER-STATE-OWNERSHIP"
related: ["0067", "0315"]
implementation_prs: []
---

# RFC-0294: Remove workspace Goal horizon

Workspace Goal no longer carries a short/mid/long classification. Priority,
status, timestamps, Goal/Task relations, and explicit scheduling conditions are
the typed sources of truth. Dashboard grouping and orphan-task logic consume
those fields directly.

This decision record remains because Goal store, workspace queries, tool schema,
dashboard accessors, and their tests cite RFC-0294. See
[`KEEPER-STATE-OWNERSHIP.md`](../KEEPER-STATE-OWNERSHIP.md).
