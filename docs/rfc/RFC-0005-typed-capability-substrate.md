---
rfc: "0005"
title: "Withdraw the typed command-policy substrate"
status: Withdrawn
created: 2026-04-17
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: null
related: ["0091", "0131", "0160", "0208"]
implementation_prs: []
---

# RFC-0005: Withdraw the typed command-policy substrate

## Decision

This RFC is withdrawn. It correctly introduced structured argv, Shell IR,
typed paths, and explicit parse errors, but then made executable names and
inferred command classes an authorization substrate. That second half coupled
the generic executor to product policy and created a hierarchy that blocked
ordinary Keeper work.

The retained execution boundary is narrower:

- structured argv and typed input are validated at the parser boundary;
- path jail and selected-sandbox containment are objective execution
  invariants;
- unsupported syntax, unavailable containment, spawn failure, and process
  failure are explicit results;
- executable names, subcommands, and guessed reversibility do not authorize or
  deny an operation;
- an external effect is settled by the product-neutral Keeper Gate through an
  exact Always Allowed rule, configured LLM Auto Judge, or non-blocking HITL.

The already-landed representation work remains valid where it serves those
objective invariants. The unfinished command-policy phases must not be
implemented or recreated under a new type name.
