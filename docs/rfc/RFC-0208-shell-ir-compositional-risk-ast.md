---
rfc: "0208"
title: "Withdrawn compositional Shell IR policy algebra"
status: Withdrawn
created: 2026-06-01
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate"
related: ["0005", "0042", "0054", "0131", "0160"]
implementation_prs: []
---

# Withdrawn compositional Shell IR policy algebra

## Decision

This RFC is withdrawn. Pipelines and commands are not assigned a MASC-local
policy rank, and parsed stages are not folded into a global permission floor.
Shell IR remains useful for syntax, typed argv, explicit redirects, execution
context, and sandbox dispatch only.

Requests needing a subjective external-effect decision go through the
[non-hierarchical Keeper Gate](../spec/05-keeper-agent.md#inv-keeper-008-non-hierarchical-effect-gate).
The Gate chooses among exact Always Allowed, configured LLM Auto Judge, and
non-blocking HITL without pausing unrelated Keeper lanes.

## Historical note

The June 2026 draft investigated pipeline coverage and duplicated policy
surfaces. It correctly exposed authority drift, but its algebra, floors,
telemetry plan, and implementation phases are retired.
