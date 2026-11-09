---
rfc: "execute-background-through-the-tool-outbox"
title: "Execute run_in_background: the result comes back as a tool-result receipt"
status: Draft
created: 2026-11-08
updated: 2026-11-09
author: vincent
supersedes: []
superseded_by: null
related: ["spawn-a-process-that-outlives-the-call", "keeper-async-fleet-continuity"]
---

# Execute run_in_background: the result comes back as a tool-result receipt

## 1. Problem

An Execute call holds the Keeper's turn until the command exits or reaches
`timeout_sec`. Nothing else the Keeper has queued starts in that time.

Measured in the tool-call ledger (`~/me/.masc/tool_calls/2026-11/`, rows with
`record_kind == "tool_call"`, `tool == "Execute"` and `ts` in
[2026-11-05T00:00Z, 2026-11-08T00:00Z)). The script and its output are in
`docs/evidence/execute-background-2026-11/`.

| Execute calls | count | time |
|---|---|---|
| all Keepers | 26,733 | 67.79 h |
| `github-pr-checker` and `pr-updater`, command contains `sleep N`, 60 s or longer | 159 | 18.68 h |
| ended with exit code 124 (the timeout), any duration | 34 | 2.86 h |

The 159 sleeping calls are polls of the form
`sleep N; gh api repos/…/actions/runs/N`. `masc_schedule_create
until_github_run` already waits for a run and wakes the Keeper; the 11-06
measurement found neither Keeper had ever created a schedule. That tool covers
one kind of wait. A build, a test run or a download has no watcher, and the
only way to wait for it is a call that blocks.

What the measurement does not show: a latency gain. Of 288 Keeper-to-Keeper
delegations that ended in the same window, 1 completed while its submitter was
inside an Execute of 60 s or longer, and 13.1 s of that Execute remained. Freeing the turn is worth the held time above, not a faster
Delegate.

## 2. Design

### 2.1 The parameter

`tool_execute` takes `run_in_background` (boolean, default `false`). With
`true`, the call returns at once:

```json
{"ok":true,"status":{"kind":"started"},"request_id":"…","delivery":"async: …",
 "typed":true,"execution_time_ms":12}
```

`argv`, `command`, `shell`, `cwd`, `timeout_sec` and `intent` mean what they
mean in the foreground. `timeout_sec` is the only bound on the run; the async
transport has no deadline of its own.

The start result is an Execute payload: it has the members the Execute output
schema requires (`status` with a `kind`, `typed`, `execution_time_ms`). A
composition plan node that sets `run_in_background` therefore completes with the
start result, and the result of the command arrives as a receipt.

### 2.2 What is checked before it returns

`Keeper_tool_execute_runtime.handle_tool_execute_typed` takes `?defer`. The
endpoint, the cwd jail and the typed input are checked on the calling turn, so
a refusal there comes back at once, as in the foreground. `defer` receives the
rest of the call, a function of the sandbox factory, and returns what the caller
gets. Without `?defer` the rest runs in place, so every existing caller is
unchanged.

The Gate decision, the sandbox and the process belong to the rest. They run in
the worker.

Two things differ from a foreground call because the run outlives the turn:

- A `masc` stage in a shell line is refused, as in a lane without a turn
  (`Keeper_shell_tool_command.refuse_reserved_command`). The stage routes through
  the context of the calling turn, which the worker must not hold.
- The request record and the receipts are files. They keep the arguments with
  credential patterns masked (`Observability_redact.redact_json_value`), as the
  tool-call ledger does; the command runs with the arguments as sent.

### 2.3 Where the run lives

`Keeper_execute_background.defer` submits the rest to
`Keeper_msg_async.submit_with_request_id` on the server-lifetime switch. The
worker binds its own request switch as the turn switch and creates its own
sandbox factory, which it cleans up when the worker ends. The calling turn's
factory is not used: it is turn-scoped and cleaned up when that turn ends. The
async composition worker does the same.

The request record keeps the call's arguments in `request_context`.

### 2.4 How the result comes back

When the rest returns, the worker writes a receipt to the Keeper's tool-result
outbox and calls `Keeper_client_tool_outbox_wake.notify`. The Keeper is woken
with `Tool_result_ready`, and every later request carries the receipt until a
completed turn acknowledges it. This is the path an ended vendor turn already
uses for results it could not receive, and every runtime kind reads it.

```json
{ "thread_id": "execute_background", "turn_id": "<request_id>",
  "call_id": "<request_id>", "tool_name": "tool_execute",
  "arguments": { … the call … },
  "response": { "request_id": "…", "outcome": "completed|deferred|failed|unfinished",
                "result": { … } } }
```

For `completed`, `deferred` and `failed`, `result` is the payload the foreground
call would have returned. For `unfinished` it is
`{"ok": false, "message": …}`.

`thread_id` and `turn_id` hold a vendor session and turn in the receipts the
outbox was written for. A background run has neither, so `thread_id` names the
producer and `turn_id` repeats the request id.

A Keeper whose runtime route cannot receive receipts
(`Keeper_client_tool_outbox_wake.route_can_consume`) gets a refusal and nothing
starts.

### 2.5 When the run does not finish

- The worker is cut off, by an operator or by the runtime, whether the command
  is running or has not started: `Keeper_msg_async` calls the abort callback of
  `defer` before it records the request as cancelled. The callback writes an
  `unfinished` receipt that names who cancelled. If the callback returns an
  error, the request is recorded as `Persistence_failed`.
- The command has ended and its result is in hand: the receipt write is
  protected from cancellation, so a cancellation during the write does not
  turn a finished run into an `unfinished` one.
- The handler raises: a protected `unfinished` receipt, and the request ends as
  a failure.
- The process dies without a clean stop: the record stays non-terminal. At
  startup, `deliver_unfinished_runs` writes an `unfinished` receipt for each
  such record of this producer, then `recover_lost_disk_records` settles the
  records. A record whose end was already written as a receipt (the crash fell
  between that write and the settle) has a receipt with its request id in the
  outbox, and no `unfinished` one is written. A crash between the `unfinished`
  write and the settle repeats the receipt with the same bytes, and the outbox
  names a receipt by its digest, so the file is the same file.

An `unfinished` receipt says the exit status was not recorded and the command
may have run to its end, stopped partway or never started. Whether a process
inside the Keeper's container survives a server stop depends on the sandbox
backend, and the receipt claims neither.

## 3. Limits of this change

- The model reaches the run by its request id through
  `keeper_composition_status` and `keeper_composition_cancel`. They call
  `Keeper_msg_async.poll` and `cancel` with the request id and the calling
  Keeper, and neither looks at what produced the request. Both are deferred
  tools, so the start result names them and the loader that attaches them
  (`keeper_tool_search`). `timeout_sec` is the other bound. The `unfinished`
  receipt of a cancelled run says an operator cancelled it, whoever called
  `cancel`: `cancelled_cause` has `Operator_request` and `Runtime_cancellation`
  and no Keeper case.
- The ledger row of the Execute call is the `started` result, with no duration.
  Execute duration statistics undercount background time until a row is written
  at completion.
- A `request_effect` call that needs approval returns `deferred` in the
  receipt, not at the call. `Keeper_gate_replay` replays an approved call in the
  foreground.
- The outbox frames receipts as "retained after the previous vendor turn
  ended". For this producer they are results that arrived after the turn
  ended.
- A receipt reaches a Keeper in a later run, not in the run that started the
  command. `Keeper_client_tool_outbox.run_carrier_load` reads the outbox on the
  first call of a run and returns that snapshot for the rest of the run, and
  `settle_after_turn` acknowledges only that snapshot. A receipt written while
  a run is going is first carried by the next run. In a run that installs the
  arrival block (`keeper_run_tools_hooks.ml`, `RFC-arrived-stimuli-reach-the-running-turn`),
  the queue row of the receipt is listed in a later round as
  `tool_result_ready receipt_id=<id>` (`Keeper_reaction_ledger.stimulus_payload_preview`).
  The id is the SHA-256 of the receipt (`Keeper_client_tool_outbox.receipt_ids`), a
  number the model never held, so the line goes on with the receipt's own
  `call_id`, `tool` and `outcome`, each a JSON string.
  `Keeper_client_tool_outbox.summary_reader` reads them from the outbox when the
  row is listed. For a background run `call_id` is the request id the start
  result named, and `outcome` is `completed`, `deferred`, `failed` or
  `unfinished`; a vendor turn's receipt has no `outcome`. A receipt the outbox no
  longer holds, or an outbox that cannot be read, leaves the line as it was. The
  line does not carry the result: the run's own way to see it is
  `keeper_composition_status`. Five background runs ended 4.3 to
  197.1 s after the start. The run that started each one made 10 to 104 more
  tool calls after the end. The next run's first tool call came 130 to 472 s
  after the end in four cases, and the fifth had none when it was read. One of
  the five Keepers asked `keeper_composition_status`, 94 s after the end. Four
  of the five ran on the Muse lane and one on the Claude Code lane.
  `keeper_turn_driver.ml` runs them through `Keeper_muse_runtime.run` and
  `Keeper_claude_code_runtime.run`, and neither file references
  `Keeper_run_tools`, so when the five runs were read those runs showed no line for
  the receipt. #50365 appends the arrived rows to the tool results of official
  clients (`Keeper_official_client_host.arrival_source`), and the line above is
  the one they show. A command that ends in 4 to 16 s returns in that time
  as a foreground call (three of the five). Figures and definitions are in
  `docs/evidence/tool-efficiency-before-after-2026-11/README.md`, section
  「스크립트 밖에서 센 값」, entry 「background Execute 5건」. Carrying newer
  receipts inside a run would change
  the one-snapshot-per-run contract of
  `RFC-retained-results-carrier-shrinks-to-an-address`, and this change does
  not.
- If the Keeper acknowledged a receipt before a crash that left the request
  open, the outbox no longer shows the receipt, and the next start writes
  `unfinished` for the same `request_id`. A receipt is acknowledged only after a
  completed turn, and the settle follows the receipt write directly.
- No bound on the number of background runs of one Keeper. In the
  2026-11-05..07 ledger no Keeper had more than one Execute call of 1 s or
  longer running at once (22 Keepers), so this change is the first source of
  parallel Execute within a Keeper. A run ends at `timeout_sec`, and the docker
  sandbox sets `--pids-limit` and `--memory` on its container
  (`keeper_sandbox_docker.ml`). The limits of the other sandbox backends were
  not examined. A bound on active runs would be a new gate, and there is no
  measurement yet to choose its number from; whether runs pile up is read from
  the ledger after deploy, and the bound is decided then.
- If the write of the receipt of a finished run fails, such as on a disk error,
  the model has only the start result. The failure is in the log and in the
  result `Keeper_msg_async` keeps for a poller; nothing retries the write.
- If the startup receipt write fails, recovery settles the record as lost
  anyway. The log line is the only trace of that run.
- Receipt writes run inside a cancellation guard. Whether the executor pool is
  still alive while the server stops, and how long the guard holds the stop,
  were not examined.
- The worker, the abort callback and the startup path are not covered by tests
  in this change. The receipt builders, the start result against the Execute
  schema, and the outbox round trip are.

## 4. Rejected alternatives

- **A live handle with `wait`, `read` and `stop`.** That is
  `RFC-spawn-a-process-that-outlives-the-call`. It answers a process that has
  no end, such as a TUI. A command that ends needs only its result, so this
  change leaves handles to that RFC.
- **A new stimulus variant and a registry of running commands.** The outbox
  already carries a durable result to a Keeper and wakes it. A second path
  would also need its own restart handling.
- **A barrier that holds a turn until all background results are in.** That
  makes the Keeper's next action a function of past results, which the
  constitution assigns to the Keeper.
- **Raising `until_github_run` adoption by prompt.** The prompt of both Keepers
  already tells them to use it.

## 5. Verification after deploy

1. A Keeper runs `{"command": "sleep 20; echo done", "run_in_background": true}`.
   The call returns `started` in under a second, the Keeper's next turn is not
   held, and a `Tool_result_ready` turn follows with a `completed` receipt that
   carries `done`.
2. Stop the server while a background run is going. After the restart the
   Keeper receives an `unfinished` receipt for that `request_id`.
3. Compare the held Execute time of `github-pr-checker` and `pr-updater` with
   the 18.68 h above, over a window of the same length.

### Observed 2026-11-08 to 2026-11-09

1. Five background runs started, from `sangsu`, `code-reviewer-father`,
   `glossary-maniac`, `ocaml-agent-ic` and `polisher`. The start calls
   returned in 5.6 to 42.1 ms. Each Keeper's turn went on after the start (10
   to 104 more tool calls once the command had ended). All five commands ended
   with `ok` true. The `sleep 20` probe was not run.
2. Not checked.
3. Not measured with the definition above. The server restart at 2026-11-08
   23:07Z started the build with #50012; in the 2 h 56 min windows around it
   the two Keepers made 71 Execute calls before and 131 after, with 0 and 1
   `sleep N` polls.

## 6. Workaround self-check

- **Telemetry as the fix?** No. This adds a way to run a command without
  holding the turn.
- **String classifier?** No. `outcome` is the typed disposition, and
  `raw_output` is carried as text without being parsed.
- **N of M?** One tool, one parameter, one delivery path.
- **Cap, cooldown, dedup, repair?** None. The outbox names a receipt by its
  digest, which is what makes a repeated write harmless.
- **Test backdoor?** `For_testing` exposes pure builders only.
