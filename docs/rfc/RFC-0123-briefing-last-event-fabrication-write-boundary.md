---
rfc: "0123"
title: "Briefing last_event fabrication — option-typed write boundary"
status: Implemented
created: 2026-05-17
updated: 2026-06-04
author: vincent
supersedes: []
superseded_by: null
related: ["0042", "0077", "0088", "0110"]
implementation_prs: [15976]
---

# RFC-0123: Briefing last_event fabrication — option-typed write boundary

## §1 Problem

`compact_session_json` used to force every session summary to carry a
`last_event` object, even when `recent_events` was empty. That shape made
absence look like an observation and forced downstream dashboard, handoff,
and debug consumers to branch on extra provenance metadata.

Root cause: the compacted briefing schema modeled `last_event` as a
required record. Empty sessions had no honest value to put there.

## §2 Implemented Contract

`last_event` is now nullable:

```ocaml
type session_summary = {
  last_event : last_event_record option;
  recent_events : event list;
  ...
}
```

JSON serialization:

- `last_event: null` when `recent_events` is empty.
- `last_event: { ... }` when a real event exists.
- No embedded provenance discriminator is emitted.

The display layer may still render an empty-state message, but the data
layer no longer invents an event-shaped object.

## §3 Caller Behavior

Consumers branch directly on the optional field:

```ocaml
match summary.last_event with
| Some event -> render_event event
| None -> render_empty_state ()
```

Briefing metadata gaps use `null` or empty fields for missing optional
scalars. They no longer depend on string placeholders for absent values.

## §4 Completed Cleanup

- `compact_session_json` emits `last_event = null` for empty sessions.
- The last-event provenance module was removed.
- The legacy metrics backend counter for last-event provenance was removed.
- Briefing compactors now serialize missing optional scalars as JSON `null`.
- Mission briefing gap/section tests cover the nullable contract.

## §5 Acceptance

- [x] `compact_session_json` nullable `last_event`.
- [x] Empty, single-event, and multi-event tests updated.
- [x] Dashboard briefing sections consume nullable briefing fields.
- [x] Provenance module removed.
- [x] Provenance counter removed.

## §6 Non-goals

- JSONL log retention policy.
- Mission briefing display ordering or grouping.
- Tool-pair repair policy from RFC-0110.

## §7 Number Allocation Note

Allocated as RFC-0123. Ledger advanced 0109 to 0124; skipped numbers remain
reserved against reuse under the monotonic ledger policy.
