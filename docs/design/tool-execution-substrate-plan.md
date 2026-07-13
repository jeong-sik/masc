---
status: withdrawn
updated: 2026-07-13
scope: historical tool-execution decision plan
---

# Tool Execution Substrate Plan

> **Withdrawn.** The previous plan made the execution substrate responsible for
> tool admission, command semantics, risk classification, credential policy,
> and product-specific workflow guidance. Those concerns do not belong in the
> generic Keeper execution boundary. The original proposal remains available in
> git history; it is not an implementation plan.

## Why It Was Withdrawn

The plan created a second authorization system below Gate:

- a fixed list of preferred tools
- admissibility rules for adding tools
- Shell IR risk and write classes
- command and credential allowlists
- product-specific CLI guidance
- receipt fields that encoded the same policy hierarchy

That coupling made a generic tool or connector depend on product meaning and
made a new capability require changes across descriptors, Shell IR, policy,
tests, prompts, and receipts. It also allowed deterministic classifications to
override the request-local model judgment that Keeper is configured to use.

## Retained Boundary

The useful substrate is deliberately smaller:

- Tool descriptors carry typed invocation data and routing identity.
- Execute input carries structural command data such as executable, argv, cwd,
  and an explicitly typed pipeline. It does not carry a risk rank.
- Shell IR, when used, represents command structure. It does not decide whether
  an operation is safe, privileged, destructive, or operator-only.
- BasePath, path-jail, schema, sandbox, and resource-containment checks enforce
  objective execution invariants.
- Receipts record what was requested, which boundary decided it, what ran, and
  the explicit result or error. They do not invent a policy class.
- OAS remains the provider/model-call and agent-lifecycle boundary. It does not
  learn MASC tools, products, Gate policy, or connector semantics.

Invalid typed input, an escaped path jail, or an unavailable sandbox is an
explicit execution error. This is containment, not a risk tier or an
authorization verdict.

## Replacement Flow

1. Decode the typed Tool request.
2. Validate only objective representation and containment invariants.
3. Resolve an exact configured Always Allowed match, if one exists.
4. Otherwise ask the configured LLM Auto Judge about this concrete request and
   current context.
5. If that decision requires a person, persist a request-local HITL item without
   blocking the Keeper lane.
6. Dispatch the unchanged typed request after an allow decision.
7. Record the complete decision and execution outcome, including errors.

No tool name, executable name, vendor, product, effect label, or Shell IR shape
may silently skip this flow or manufacture an allow, deny, pause, or escalation.

## Consequences

- There is no canonical primitive-tool whitelist in this document.
- There is no generic rule that a command should or should not become a Tool.
- There is no Shell IR risk classifier, effect class, policy floor, or command
  allowlist in the execution substrate.
- GitHub, Discord, browser, image, and other product workflows belong to their
  Tool or Connector adapters and user-facing skills/runbooks, not Gate or Shell
  IR.
- Adding a Tool requires its typed contract and implementation, not an update to
  a global product-aware authorization taxonomy.

The HTML companion is historical explanatory material and must not be used as
an active design SSOT.
