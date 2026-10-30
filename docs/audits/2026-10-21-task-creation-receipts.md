# Exact original Task creation facts

This source unit extends #44547's retained original creation request with durable
request-to-Task attribution. It does not complete the six-axis TUI/Keeper goal.

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Lost response after creation | Original command retained; JSON-RPC id not persisted with Task | Same primary backlog replacement commits the original client id and created Task id |
| Equal titles | Cannot identify the original creation from title | Exact opaque request id lookup; title/body are never searched |
| Repeated original id | Each accepted call creates a separate Task | Same semantics; lookup returns ambiguous with every recorded Task id |
| Missing receipt | No exact lookup | not_observed, never proof of non-creation or retry permission |
| Deleted/archived Task | Task observation can disappear | Creation fact retained independently; recorded does not claim current status/existence |
| Unreadable primary | Recovery copy may be available for observation | Exact proof lookup refuses it; no successful empty/fallback answer |

## Contract and source

`task_creation_request_id` is a private opaque non-blank string at public OCaml
boundaries. Input bytes are preserved. A missing optional id means an uncorrelated
creation. Present null/non-string/blank/duplicate public fields are rejected.
The id is supplied by a client, is not a credential and does not grant authority.

`Workspace_task_create.add_task_with_result` adds a typed creation fact to the
same `new_backlog` as its Task under the existing backlog lock and protected
settlement. Existing Goal -> backlog -> links ordering, Skills/contract parsing,
predecessor validation, post-commit activity and broadcast remain. A failure
before commit creates no fact; an error after primary commit can still leave a
fact. This is why tool errors remain inconclusive until read separately.

The existing `masc_tasks` tool accepts an explicit `creation_request_id` query,
optionally bound to `expected_workspace`. It returns the exact id, canonical
workspace, backlog version, and a creation_receipt with state recorded,
not_observed or ambiguous and task_ids. Status/include filters cannot be combined
with this query. Ordinary task listing retains its existing implementation.
Strict primary corruption is a runtime error, not unobserved. Reads never create,
repair, retry, deliver a Keeper handoff or assert current Task completion.

TUI creation now sends its original immutable request id as this correlation
argument. TUI automatic reconciliation and a visible inspect action remain next
work; `/task-recover` continues to copy retained input without transmission.
No preexisting Task is assigned a guessed request id.

Backlog record updates in transitions, GC/archive and deletion retain the creation
facts. Task id allocation includes them so a retained fact cannot later point to
a newly reused id. There is no new file/rename protocol, cap, TTL, polling timer,
retry, duplicate suppression, env setting or runtime permission.

## Before/After quantities and costs

Structural quantities only: correlated durable request-to-Task facts per TUI
creation change from 0 to 1; required primary commits remain 1; automatic creation
replays remain 0. No throughput or latency improvement is measured.

For R retained correlated creations, each fact holds the opaque request id and
Task id. Backlog encoding/decoding, append, id reservation and explicit lookup
add O(R) work; query retains all matches including ambiguous repeated ids. Empty
backlogs add an empty creation-facts field. Facts are retained for the workspace
lifetime and can grow. Existing event/archive scans and physical storage costs
remain. No body copy or additional durable file is introduced. Failed, cancelled,
interrupted, unstarted and unfinished attempts remain in the full goal's matched
actual Before/After requirements; none was executed/measured in this unit.

## Authored scenarios (unexecuted)

Two additional cases extend the actual in-process MCP and persistent-workspace
fixture in test/test_tui_task_cancel_result.ml. They use production TUI creation,
wire encoders, server handlers and strict backlog reads. They assert actual Task
resources, not invocation counts or screen wording/layout:

1. Discard the response after actual creation, read its exact id, add an equal-title
   Task with another id, preserve the original proof, observe missing as unobserved,
   repeat the original request as another real creation and observe ambiguous;
   actually delete the original Task and retain both original creation facts.
2. Refuse invalid/duplicate/null ids and foreign workspace/filter combinations
   without changing Task resources; corrupt the actual primary creation-facts field
   with a valid recovery available and refuse both proof lookup and later creation
   without repairing or replacing that primary.

Existing full-backlog fixture constructors only receive the new empty field.
No new helper/count, snapshot, wording, layout or PTY test is added.

Verification is parsing only, five changed interfaces before implementations,
plus source/diff/direct-dependency review and TOML parsing. No type checking,
warning checking, linking, Dune build, test execution, CI dispatch/watch, native
TUI/HTTP network/provider/controller run, installation/restart or live writes.
No physical overlap, restart recovery, visible paint/input, actual Loading root
cause or measured speedup is proven. Independent current-head source review and
whole-stack integration remain separate. External lower restack is preserved;
the recorded #44199 -> #44211 missing ancestry boundary is not resolved here.
