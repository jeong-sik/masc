---
rfc: "tui-measured-operator-home"
title: "A measured Dashboard with Work and Usage as distinct destinations"
status: Accepted
created: 2026-09-25
author: dancer + codex
supersedes: ["0464", "tui-operator-ia:3.1"]
superseded_by: null
related: ["0462", "tui-operator-ia"]
---

# A measured TUI operator home

## Decision

The operator's 2026-09-25 review of the live Overview replaces the home-screen
decision in RFC-0464 and the top-level menu proposed in
RFC-tui-operator-ia §3.1. The first screen answers how the system and its work
are progressing. It does not repeat the task list, Keeper roster, or quota
graphs from their own destinations.

The top-level ring is **Dashboard, Work, Keepers, Usage, Board, Workspace,
System**. Activity and server logs live under System. Approvals and Keeper
questions are reachable from Work (`p`) and through the command palette. The
remaining operational screens retain their palette or parent-screen paths.

## Each destination's question

| Destination | Question | Primary content |
|---|---|---|
| Dashboard | Is the system healthy, and is work progressing? | Health, explicit Goal observations, completed Task flow, attention and data coverage |
| Work | What needs action, and what counts as done? | Goals, active Tasks, Task Review, Task Verdicts, approvals and questions |
| Keepers | Who is running and what happened to this Keeper? | Roster, status, detail, chat, calls, changes and Keeper tools |
| Usage | What resources were reported, by which scope and when? | Provider quota windows and history, Keeper token/cost reports, operational telemetry |
| Board | What did Keepers post? | Board posts and replies |
| Workspace | What is in the working tree? | Repositories and code |
| System | How is the runtime configured and what happened? | Runtime, configuration, Activity and logs |

Dashboard has no second Team/Fleet table. Keepers owns the roster; Work owns the
Task list. This removes two representations of the same rows that had different
selection and refresh behavior. The task trend on Dashboard is a summary with
an explicit source and period, not another Task list.

## Measurement contract

- A Goal's actual value is a recorded observation with a source, actor, time,
  and exact criterion revision. A Task count is displayed separately as
  `linked tasks`; it is never converted into the Goal's actual value.
- Work displays an observation only when Goal ID, criterion revision, metric,
  and target agree with the current Goal. A changed criterion makes the old
  observation unavailable for that Goal. Unknown or unreadable values remain
  unknown or unreadable.
- Task progress uses retained completion records and names the covered period.
  Snapshot totals and completed Task records have different meanings and are
  labelled accordingly. The UI does not extrapolate missing days.
- Provider quota rows retain the provider's reported window, observation time,
  reset time, state, and quota scope. A scope is an opaque identity, not a
  verified human account. The Usage trend displays exact recorded reports by
  UTC day and says how many days were reported. Multiple scopes remain
  separate. Missing reports do not become zero usage.
- Keeper token and cost figures show reported and missing coverage. A missing
  cost is not zero cost. Loading, partial, failed, and unavailable reads are
  visible states rather than numeric estimates.

The UI must not infer progress, quota use, cost, or health from text matching,
task-title similarity, elapsed time alone, or other heuristic measurements.
Follow links from a summary to the underlying Work or Usage evidence where
the API provides a stable identity.

## Navigation and verification

The seven names above are the visible Tab ring. Work has Goals/Tasks and the
Task Review/Verdicts cycle. Usage keeps quota and Keeper reports together;
historical report coverage and operational telemetry remain reachable there.
System exposes Activity and logs without making the event stream the first
screen. `go System / <pane>` opens each configuration pane.

The TUI guide, key hints, palette, and PTY scenarios follow this decision in
the same change. A PTY capture must prove the Dashboard summary, Work Goal
evidence, Usage report coverage, and System Activity path against controlled
fixtures. Source parsing or API presence alone does not establish that the
first screen actually shows the intended information.
