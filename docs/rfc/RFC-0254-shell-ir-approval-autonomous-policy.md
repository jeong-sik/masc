---
rfc: "0254"
title: "Shell IR Approval Gate — Autonomous Production Policy"
status: Withdrawn
created: 2026-06-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0005", "0160", "0208"]
implementation_prs: []
---

# RFC-0254: Shell IR Approval Gate — Autonomous Production Policy

**Status**: Withdrawn
**Date**: 2026-06-17
**Withdrawn**: 2026-07-12

## Decision

The per-command approval hierarchy described by this RFC was removed. It put
product authorization, command-name knowledge, and speculative effect grading
inside the generic Shell IR executor. That coupling blocked ordinary Keeper
work and duplicated decisions that belong at the product Gate boundary.

The execution core now has one responsibility: accept structured argv/IR,
validate syntax and local paths, dispatch to the selected sandbox target, and
report the process outcome. It does not infer whether an operation should be
authorized.

Product authorization remains an outer decision. A caller may obtain an
operator or LLM decision before invoking the executor, but that decision must
not be encoded as executable-name tables or an approval envelope in
`masc_exec`.

Sandbox isolation, path containment, resource cleanup, and observability remain
in force. Removing this RFC does not turn those objective boundaries off.
