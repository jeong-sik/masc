---
rfc: "0080"
title: "Registered descriptors are the tool-surface SSOT"
status: Implemented
created: 2026-05-14
updated: 2026-07-13
author: vincent
implementation_prs: [15207, 15268, 15271]
---

# RFC-0080 — Registered descriptors are the tool-surface SSOT

The exact set of valid registered descriptors, names, and schemas is the model
tool surface. There is no second policy TOML, hidden audience, maintenance
class, product list, allowlist, denylist, or semantic readiness projection.

Transport aliases do not create tools. Invalid schema registration is an
explicit startup error. External effects reach their actual handlers and the
generic Gate; objective input/path/sandbox failures are returned there.
