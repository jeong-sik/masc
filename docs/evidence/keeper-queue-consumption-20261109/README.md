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
  effect or failure takes priority over handoff. A failed read-only handoff
  probe logs a warning and keeps the current turn running; it cannot turn a
  completed tool into an unknown-outcome failure. Cancellation still propagates.
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
| Historical chat admission, terminal precedence, native tool boundary, checkpoint resume | `Test`, [run 42610164608](https://github.com/jeong-sik/masc/actions/runs/42610164608), ref `fix/keeper-queue-handoff-20261109`, head `e4b22934d5e498e604690f504ec52f08ae5b5777`, conclusion `success`; before the later handoff-probe error repair |
| Selected suites in that run | `test_keeper_owner` 112, `test_keeper_turn_outcome` 44, `test_keeper_official_client_host` 97, `test_keeper_repetition_scope` 12, `test_keeper_agent_core_result_outbox` 12; 277 tests passed |
| First upper run | `Test`, [42612825975](https://github.com/jeong-sik/masc/actions/runs/42612825975), ref `fix/keeper-queue-batching-20261109`, head `5c47fb86b093acffc4a44b2a9e9c7f4b800dd0b6`, conclusion `failure`: the new test runner lacked an explicit operation record type. The one-line annotation is the repair; behavior tests did not run. |
| Second upper run | `Test`, [42613785602](https://github.com/jeong-sik/masc/actions/runs/42613785602), ref `fix/keeper-queue-batching-20261109`, head `c598ff72b050bc76e31f0876768520feabc0ac5f`, conclusion `failure`: the new test watchdog used result-returning `with_timeout` for a plain-value callback. It now uses `with_timeout_exn`, matching the existing exception handler. Behavior tests did not run. |
| Historical scheduled batching and combined handoff scenario | `Test`, [42615809773](https://github.com/jeong-sik/masc/actions/runs/42615809773), ref `fix/keeper-queue-batching-20261109`, head `4774dbfa500b15b70f92d441108bd6ce43cb43ad`, conclusion `success`. `test_keeper_connector_attention_batch` 34 and `test_keeper_agent_core_result_outbox` 12 tests passed; before the later handoff-probe error repair. |
| Handoff-probe error repair | `Test`, [42622644530](https://github.com/jeong-sik/masc/actions/runs/42622644530), ref `fix/keeper-queue-handoff-20261109`, head `340166d2741152c5ac2625126ea09934d3a1308b`, conclusion `success`: `test_keeper_turn_outcome` 44 and `test_keeper_official_client_host` 97 tests passed. |
| Local source checks | OCaml 5.5.2 parsing of changed OCaml files, raw typechecking of Owner and intake, `git diff --check`; no local Dune build |
| Independent review | One separate agent reviewed both units. Two reply-routing P2 findings were fixed: Slack thread conflation and no-delivery schedules erasing a connector route. The reviewer found no remaining P0/P1/P2 in the repaired scopes. This is source review, not a GitHub account approval or runtime observation. |

The two successful runs above are historical. Commit `340166d27411` changes
`keeper_agent_run.ml` and its two boundary-consumer tests so a failed advisory
read cannot reclassify a settled tool as `Effect_outcome_unknown`. It also
rests on the newer main base `e025a852567e`. The earlier 277 and 46 test results
do not establish that new error path or the complete rebased tree. The intake
implementation and the combined Owner/SQLite fixture remain unchanged from
the recorded upper run; their earlier results retain only that recorded scope.

The added error cases exercise the actual official-client host wrapper and
the native boundary adapter with a returned probe error. They do not execute
the production `run_turn` closure while the registry is stopping. Independent
source review checked that closure, terminal precedence and cancellation
propagation. Re-review of the repaired head remains a separate GitHub action.
The local fragment checker passed both PR-number citations. An earlier
specialist request failed because its provider's weekly quota was exhausted;
delivery acceptance is not counted as completed review.

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

A later read-only observation on 2026-11-09, 12:53:14Z–12:55:14Z, found the
running binary at `e2c38ca5ad1d850f2890b4e17d0ace08f7eea6b0`. Its reported
and directly computed executable SHA-256 both were
`447b0b00872c1affb6f5e189a282c3491b1c1259f2466ecf8ade554a4568ba7a`.
That source and binary still contain the old singleton schedule scope and
omit this repair. It is not deployment evidence for this stack. The local
capture is `artifacts/keeper-queue-live-20261109T125156Z/`; it is not a published
artifact or a measurement of the repaired binary.

Remaining non-blocking review notes: chat handoff shares the existing durable
checkpoint stop reason and has a distinct keeper-scoped log, rather than its
own metrics label. Per-boundary lookup cost has not been measured. Readiness
is not a reservation: cancelling the queued chat before settlement can leave
the saved autonomous turn waiting for its next normal admission opportunity.

Handoff occurs at a completed tool boundary. It cannot interrupt a shell or
vendor built-in tool that is still executing, and adds no time, token or round
limit. A running tool's remaining time is outside this latency guarantee.
