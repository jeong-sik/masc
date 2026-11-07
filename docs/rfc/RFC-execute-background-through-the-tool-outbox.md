---
rfc: "execute-background-through-the-tool-outbox"
title: "Execute run_in_background: the result comes back as a tool-result receipt"
status: Draft
created: 2026-11-08
updated: 2026-11-08
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
{"ok":true,"status":"started","request_id":"…","delivery":"async: …"}
```

`argv`, `command`, `shell`, `cwd`, `timeout_sec` and `intent` mean what they
mean in the foreground. `timeout_sec` is the only bound on the run; the async
transport has no deadline of its own.

### 2.2 What is checked before it returns

`Keeper_tool_execute_runtime.handle_tool_execute_typed` takes `?defer`. The
endpoint, the cwd jail and the typed input are checked on the calling turn, so
a refusal there comes back at once, as in the foreground. `defer` receives the
rest of the call, a function of the sandbox factory, and returns what the caller
gets. Without `?defer` the rest runs in place, so every existing caller is
unchanged.

The Gate decision, the sandbox and the process belong to the rest. They run in
the worker.

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

- The worker is cancelled, by an operator or by a server stop: the cancel arm
  writes an `unfinished` receipt, then re-raises, so the receipt exists before
  `Keeper_msg_async` records the request as cancelled.
- The handler raises: an `unfinished` receipt, and the request ends as a
  failure.
- The process dies without a clean stop: the record stays non-terminal. At
  startup, `deliver_unfinished_runs` writes an `unfinished` receipt for each
  such record of this producer, then `recover_lost_disk_records` settles the
  records. A crash between the two repeats the receipt with the same bytes, and
  the outbox names a receipt by its digest, so the file is the same file.

An `unfinished` receipt says the exit status was not recorded and the command
may have run to its end, stopped partway or never started. Whether a process
inside the Keeper's container survives a server stop depends on the sandbox
backend, and the receipt claims neither.

## 3. Limits of this change

- No cancel or status tool for the model. `timeout_sec` is the bound.
  `Keeper_msg_async.cancel` and `poll` exist and take the request id.
- The ledger row of the Execute call is the `started` result, with no duration.
  Execute duration statistics undercount background time until a row is written
  at completion.
- A `request_effect` call that needs approval returns `deferred` in the
  receipt, not at the call. `Keeper_gate_replay` replays an approved call in the
  foreground.
- The outbox frames receipts as "retained after the previous vendor turn
  ended". For this producer they are results that arrived after the turn
  ended.
- The worker and the startup path are not covered by tests in this change. The
  receipt builders and the outbox round trip are.

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

## 6. Workaround self-check

- **Telemetry as the fix?** No. This adds a way to run a command without
  holding the turn.
- **String classifier?** No. `outcome` is the typed disposition, and
  `raw_output` is carried as text without being parsed.
- **N of M?** One tool, one parameter, one delivery path.
- **Cap, cooldown, dedup, repair?** None. The outbox names a receipt by its
  digest, which is what makes a repeated write harmless.
- **Test backdoor?** `For_testing` exposes pure builders only.
