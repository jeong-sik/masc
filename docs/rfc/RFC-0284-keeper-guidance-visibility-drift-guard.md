---
rfc: "0284"
title: "Supersede command-semantics guidance guards"
status: Superseded
created: 2026-06-23
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-012-structural-execution-invariants"
related: ["0080", "0084", "0219"]
implementation_prs: []
---

# RFC-0284: Supersede command-semantics guidance guards

## Decision

This RFC is superseded. Its incident was real—a recovery string named a tool
that did not exist—but the proposed guard was tied to a command-semantics
module and a visibility-policy layer that have both been removed.

The current boundary prevents recurrence more directly:

- every registered descriptor is model-visible unless it is an objective
  duplicate transport alias or has an invalid schema;
- the generic Execute adapter validates structured argv, paths, and sandbox
  facts without synthesizing product-specific recovery instructions;
- actual tool and process failures are returned as explicit typed results for
  the model to reason about;
- external effects use the product-neutral Keeper Gate;
- there is no hidden clone/repository command policy or phantom-tool guidance
  registry to keep in sync.

Future guidance should reference descriptors supplied in the same model turn,
not reintroduce a parallel tool-visibility or command-semantics classifier.
