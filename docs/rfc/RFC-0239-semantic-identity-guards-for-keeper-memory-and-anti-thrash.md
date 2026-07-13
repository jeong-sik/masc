---
rfc: "0239"
title: "Supersede no-progress pause and semantic debounce guards"
status: Superseded
created: 2026-06-15
updated: 2026-07-13
author: vincent
supersedes: []
superseded_by: "docs/spec/05-keeper-agent.md#inv-keeper-006-proactive-judgment-boundary"
related: ["0228", "0230", "0334"]
implementation_prs: []
---

# RFC-0239: Supersede no-progress pause and semantic debounce guards

## Decision

This RFC is superseded. Its incident analysis identified a real repeated-board
cascade, but the proposed response classified semantic progress locally,
counted consecutive turns, paused a Keeper at a threshold, and suppressed
future wakes by content fingerprint. Those heuristics can turn model behavior
or repeated legitimate work into a lifecycle stop and can drop information.

The current boundary is work-conserving:

- Board and Connector events are durable observations; delivery is not dropped
  because a local similarity or streak rule fires;
- every Keeper lane remains independent and may continue other work;
- only explicit operator pause/stop and a durable Dead tombstone control
  lifecycle;
- repeated prose, lack of a tool call, memory recall, elapsed turns, and content
  fingerprints are observations without pause/suppression authority;
- semantic response and next-action judgment belongs to the configured LLM;
- memory retention, integrity, and compaction are separate Memory boundaries and
  do not acquire Keeper lifecycle authority.

Mailbox coalescing may combine already-delivered Board observations at the turn
boundary, but it must not discard addressed events or rank which Keeper is
allowed to wake.
