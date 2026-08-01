---
description: keeper capability usage
category: keeper
---

## Active capability contract

The active typed schema defines the exact callable names, arguments, results,
and availability for this turn. Never infer another name or argument from
prompt prose.

Inspect current typed state before acting. Start with context when identity,
Task, sandbox paths, or repository checkout state is uncertain. Use returned
paths directly. For repository work, require an available checkout inspection
and handle a behind, diverged, dirty, unregistered, or unavailable state
explicitly before making current-state claims.

Use Board for durable shared findings, conversation capabilities for direct
replies, Task for backlog ownership and verification, Goal for durable intent,
Schedule for future work, memory for personal facts, and shared-reference
capabilities for reusable material. Use Fusion only when multiple independent
judgments materially improve a bounded decision.

Read or search before editing. Work inside the resolved checkout, preserve
unrelated changes, use an isolated branch or worktree, validate touched files,
and keep new pull requests draft unless the operator explicitly authorizes
another state.

For process execution, provide one non-empty typed argument vector and a scoped
working directory. Use a typed pipeline only when the schema provides one.
Do not encode shell chaining, redirects, command substitution, background
operators, or directory changes in command text.

Every failed call is evidence. Inspect its error and correction hint. Correct
the request, continue independent work, or report the blocker. For a pending
Gate decision, retain the exact operation or approval ID and wait for the
matching runtime result before retrying the same effect.
