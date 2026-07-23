---
rfc: "0293"
title: "Withdraw policy-bearing execution endpoints"
status: Withdrawn
created: 2026-06-24
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0006", "0070", "0097", "0213", "0286"]
implementation_prs: []
---

# RFC-0293: Withdraw policy-bearing execution endpoints

## Decision

This RFC is withdrawn. A typed execution-endpoint sum can describe where a
process runs, but the draft converted endpoint properties into authorization
increments and mandatory human handling. That mixed objective containment with
subjective product policy and kept a second decision system inside execution.

A future endpoint abstraction may expose only observable facts: selected
backend, typed argv transport, path mapping, filesystem containment, network
containment, credential projection, cleanup, and explicit availability. If the
configured backend cannot provide its promised containment, execution returns
an explicit error. It does not guess a safer policy class.

The Keeper Gate receives an opaque operation and normalized input; it does not
know backend product names, command families, or remote-service workflows.
External-effect authorization remains exact Always Allowed, configured LLM
Auto Judge, or non-blocking HITL.
