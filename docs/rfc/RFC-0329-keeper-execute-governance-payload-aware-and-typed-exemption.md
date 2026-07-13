---
rfc: "0329"
title: "Keeper Execute Governance Payload Mapping"
status: Rejected
created: 2026-07-08
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0254", "0309", "0318", "0319"]
implementation_prs: []
---

# RFC-0329: Keeper Execute Governance Payload Mapping

**Status**: Rejected
**Date**: 2026-07-08
**Rejected**: 2026-07-12

## Decision

This proposal attempted to repair a blanket product gate by importing the
executor's command hierarchy into Governance. That would have preserved two
competing decision systems and made Governance understand concrete tools and
their subcommands.

The replacement boundary is smaller:

1. A product Gate decides whether a requested abstract operation may proceed.
2. The Shell IR adapter validates structured command shape and workspace paths.
3. The execution core dispatches the IR to the selected sandbox and records the
   outcome.

No executor-derived command ranking or typed exemption is carried across that
boundary. If a task needs semantic judgment, the product Gate asks its configured
judge using the task and operation context; the generic executor remains
product-agnostic.
