# Keeper queue consumption repair

The reported operator message waited 1,698.3 seconds behind an autonomous turn.
A read-only query of `github-pr-checker`'s operation store on 2026-11-09 confirmed
sequence 32 eventually succeeded with that queue delay. This establishes the
delay, not a currently stuck operation. The live queue had already drained the
reported scheduled backlog when this investigation read it.

## Decisions

- A ready chat operation can take over after the running autonomous tool and
  its checkpoint settle. The Owner checks its original child token and the
  same lifecycle, shutdown, error and runner-readiness gates as chat admission.
  A queued but unclaimable operation does not repeatedly checkpoint the turn.
  Direct chat does not yield back to schedule backlog. An explicit terminal
  effect or failure takes priority over handoff.
- No-delivery scheduled requests can share a turn with other unrouted work.
  Schedules with a reply obligation can share only the exact captured reply
  route. A no-delivery schedule cannot absorb routed attention and erase its
  reply default. Queue incarnation, checkpoint retention, withdrawal and exact
  completion ACK stay authoritative for every member.
- `scheduled_wake` has no Task binding. A Task ID mentioned in the message is
  not authority to retire the request, even when that Task has completed.
- `Arrived_stimuli` is a preview, not canonical intake: it contains neither
  the full validated input nor the turn's admitted selection set. Showing it
  cannot authorize an ACK. Its separate later intake remains intentional.
  Advancing its ACK would lose work on failed or checkpointed turns. The
  existing per-run confirmation suppresses repeated previews within a run.
- Do not remove `Goals_awaiting_proof` from later requests. Agent Core's
  extra context is request-local, so omission drops the observation. Moving it
  into an official client's persistent System would instead retain an old
  Goal phase after it changes. Its current-turn Start/Resume delivery is
  covered by the existing official-client suite.

The distinction between seeing a message and owning its completed processing
also follows the [RabbitMQ acknowledgement contract](https://www.rabbitmq.com/docs/confirms).
This is design context; MASC's exact selections and terminal receipts remain
the implementation authority.

## Verification

| Scope | Evidence |
| --- | --- |
| Chat admission, terminal precedence, native tool boundary, checkpoint resume | `Test`, [run 42610164608](https://github.com/jeong-sik/masc/actions/runs/42610164608), ref `fix/keeper-queue-handoff-20261109`, head `e4b22934d5e498e604690f504ec52f08ae5b5777`, conclusion `success` |
| Selected suites in that run | `test_keeper_owner` 112, `test_keeper_turn_outcome` 44, `test_keeper_official_client_host` 97, `test_keeper_repetition_scope` 12, `test_keeper_agent_core_result_outbox` 12; 277 tests passed |
| First upper run | `Test`, [42612825975](https://github.com/jeong-sik/masc/actions/runs/42612825975), ref `fix/keeper-queue-batching-20261109`, head `5c47fb86b093acffc4a44b2a9e9c7f4b800dd0b6`, conclusion `failure`: the new test runner lacked an explicit operation record type. The one-line annotation is the repair; behavior tests did not run. |
| Final scheduled batching and combined handoff scenario | Pending the replacement selected run for the upper PR; not established by the bottom run |
| Local source checks | OCaml 5.5.2 parsing of changed OCaml files, raw typechecking of Owner and intake, `git diff --check`; no local Dune build |
| Independent review | One separate agent reviewed both units. Two reply-routing P2 findings were fixed: Slack thread conflation and no-delivery schedules erasing a connector route. The reviewer found no remaining P0/P1/P2 in the repaired scopes. This is source review, not a GitHub account approval or runtime observation. |

The combined scenario uses a real Owner and SQLite operation queue, a local
HTTP provider fixture and the actual runtime/checkpoint/outbox path: chat
arrives during a tool, remains Queued, the saved tool boundary yields, the Owner
claims and settles chat, and autonomous work resumes without replaying its
completed effect. The autonomous input is reloaded from the canonical
checkpoint store before resumption. The chat executor is a fixture runner;
this does not prove a real model's chat response or process-restart recovery.
The scheduled intake scenario checks mixed unrouted work,
same-route schedules, distinct Slack threads, both connector/schedule queue
orders, retention at a checkpoint, later progress and exact completion ACK.

These are focused behavior checks, not full regression or production proof.
The production binary observed during diagnosis was
`6a6ec4c28e2f26edcf272e37115ac2f655005f2b`; this record does not claim it contains
the repair. No production queue was edited, cleared or replayed. No dashboard
was changed, so no screenshot or UI-verification claim is made.

Handoff occurs at a completed tool boundary. It cannot interrupt a shell or
vendor built-in tool that is still executing, and adds no time, token or round
limit. A running tool's remaining time is outside this latency guarantee.
