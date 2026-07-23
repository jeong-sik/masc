---
rfc: "0084"
title: "Tool dispatch handler and observation unification"
status: Implemented
created: 2026-05-15
updated: 2026-07-13
author: vincent
implementation_prs: [15399, 15400, 15403, 15404, 15406, 15407, 15410, 15411, 15412, 15415, 15416, 15417]
---

# RFC-0084 — Tool dispatch handler and observation unification

Every registered descriptor resolves to one handler path and emits a typed
result with turn/tool correlation, timing, trace, and provenance. Observation
failure is explicit and does not rewrite the handler result.

Dispatch performs no audience, product, capability, maintenance, or risk
classification. Objective handler input/path/sandbox invariants remain local;
external effects call the generic Keeper Gate at execution time.
