# TUI conversation lifecycle wiring audit

Scope: chat output, polled Keeper activity, event-journal handoff, async Keeper detail responses. This is a source audit, not a repository-wide runtime certification.

## Confirmed findings

| Boundary | Source failure | Change |
| --- | --- | --- |
| Autonomous output → conversation | Autonomous turns have no operation journal; `Latest output` rendered the redacted 240-byte tail under the conversation. | Render a transient multiline body excerpt. Keep lane/activity/stop keys under the conversation. Do not persist successive excerpts as invented replies. |
| Session reply → history refresh | Successful history responses removed session output even when no replacement was returned. | Require exact Keeper/request and terminal reply role, or exact row identity. Preserve output on empty/partial/unrelated pages. |
| Partial journal → final history | A durable final row or journal-unavailable result excluded the partial observed block before terminal journal events arrived. | Preserve received text/tools/reasoning, close known endings, label unavailable observation, hide the durable final only when a visible journal draws its final reply. |
| Observed block → live ownership | A journal excluded from rendering could still suppress the durable final; the row memo did not depend on observed ownership. | Derive reply suppression from visible observed logs and include that set in memo validity. |

## Additional source findings

- `Keeper_schedules_loaded` accepts a delayed prior Keeper response into a singleton cache without checking the current target. A→B with B→A response order erases B's schedule reading. Rendering rejects the A stamp, leaving B loading.
- `Identity_refreshed` changes the shared Identity view/error after the operator has switched Keepers. A delayed A success clears B's view; a delayed A failure appears under B.

These detail-response races require a separate change and inverse-order response scenarios. Queue completion uses Keeper-scoped notices; chat history, calls and sandbox log loads have target/generation guards. This audit did not certify all TUI modules or production behavior.

## Validation and limits

OCaml parse checks, Python syntax checks and whitespace checks are local source checks only. The added PTY scenario exercises autonomous output with queued input, tail replacement and failed observation. Frame tests exercise durable-first journal handoff and replacement authority. Their execution must be confirmed from the current-head CI run.

Autonomous output remains a polled excerpt of the server's existing redacted preview. Full token history needs a durable autonomous-turn event source; this change does not claim to provide it. Screenshots captured by the fixture are fixture PTY evidence, not production proof. No running TUI or server was restarted.
