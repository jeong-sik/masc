---
status: runbook
last_verified: 2026-08-23
code_refs:
  - bin/masc_tui.ml
  - bin/masc_tui_render.ml
  - bin/masc_tui_loader.ml
  - bin/masc_tui_http.ml
  - bin/masc_tui_types.ml
  - bin/masc_tui_keeper_chat_recovery.ml
---

# MASC TUI Guide

Terminal UI over a MASC runtime root. It reads `.masc/` directly and, when a
server is reachable, adds the surfaces that only exist over HTTP. Five surfaces
rotate with `Tab`: Overview, Keepers, Approvals, Board, Planning, System
Logs.

## Quick Start

```bash
dune build --root . bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/me
```

`.masc` must live directly below the path you pass. The base path resolves as
`--base-path` -> `MASC_BASE_PATH` -> current directory, so the shorter form is
`MASC_BASE_PATH=~/me ./_build/default/bin/masc_tui.exe`. An installed build is
`masc-tui`.

Point it at the same root the server uses. A TUI reading one root while the
server writes another shows stale keepers with no error, because both roots are
valid on their own.

## Options

| Option | Default | Effect |
|--------|---------|--------|
| `--base-path` (`--base`) | `MASC_BASE_PATH`, then cwd | Directory holding `.masc` |
| `--port` | `8935` | MASC server port on `127.0.0.1` |
| `--refresh` | `2` | Seconds between refreshes |
| `--workspace` | derived from base path | Workspace label in the header |

## What the server changes

The TUI runs without a server. Which surfaces stay useful is not a detail - it
decides whether launching one is worth it.

| Surface | Without a server | Source |
|---------|------------------|--------|
| Keepers (list, detail, logs) | fully works | `.masc/keepers/`, turn records, metrics store |
| Overview - Tasks panel | works | `.masc/tasks/backlog.json` |
| Overview - summary, Attention | unavailable | `GET /api/v1/dashboard/briefing` |
| Overview - transport tail | unavailable | `GET /api/v1/dashboard/transport-health` |
| Approvals | unavailable | `GET /api/v1/operator`, `POST /api/v1/operator/confirm` |
| Board | unavailable | `GET /api/v1/board` |
| Planning | unavailable | `GET /api/v1/dashboard/planning` |
| Keeper message | unavailable | `POST /api/v1/keepers/chat/stream` |
| System Logs | unavailable | `GET /api/v1/dashboard/logs` |

An unreachable server is reported, not hidden. The header shows
`[disconnected]`, the surface prints the failing call, and each failed load
lands in Recent Events:

```
 MASC Board (0)  10:55:37  [disconnected]
   (data unreliable: board load failed: (GET failed: Connection Error: ...
```

A count of `0` next to `data unreliable` means the read failed. It does not
mean the board is empty.

## Surfaces

### Overview

Workspace health, agent count, pending approvals, incident count, the Attention
list, Recent Events, and active tasks.

```
 MASC Overview  [me]  10:54:52  [connected]
   Health: bad  Agents: 2  Approvals: 0  Incidents: 4
   Cluster: default          Project: me      websocket/steady  sse 3  ws 1  grpc :8936
 Attention                              | Recent Events 1-5/5
 [bad ] analyst needs operator atten~   | [10:54:52] TUI started
 [warn] sangsu has external attention   |
 Tasks
   * [task-317] Apply File_lock_eio to approval queue (in_progress @keeper-...)
   o [task-272] Add HTTP route regression coverage (todo) !
  j/k:events  q:quit  r:refresh  Tab:next  2:keepers  | Refresh: 2s | Port: 8935
```

`j`/`k` scroll the events pane, not the task list. `t` hands `j`/`k` to the
task list instead; under task focus, `Enter` opens the selected task in full -
description, status with its assignee and timestamps, handoff summary, the
completion contract's evidence list, attached files - read from the same
backlog load the list was projected from. `Esc` closes the detail, a second
`Esc` returns `j`/`k` to the events. Events are windowed against
both panel columns, so a long event wraps to the width actually available
rather than the header width.

The tail of the cluster row is what the server reports about its own delivery
paths: the primary path, queue pressure, and per-path session counts. It rides
that row rather than taking one of its own, so a short viewport does not trade
an event line for it. A path that is not listening reads `off` rather than as
zero sessions, because those are different facts, and a nonzero drop count is
spelled out - a steady queue that drops is not a healthy transport.

This tail is read only while Overview is the current surface.

Tasks show terminal states in Planning rollups but not in this list. A task
detail that is open when its task turns terminal stays open - the detail reads
the full backlog rows, not the active projection.

### Keepers

Every keeper under `.masc/keepers/`, sorted by name.

```
 MASC Keepers (10)  10:55:25
      Name                   Gen  Paused        Turns  Current Task
 >  adm-race-cf-001            1  no              498  -
    analyst                    1  no              237  task-464
    sangsu                     1  yes             182  task-317
  j/k:move  Enter:detail  Tab:next  q:quit  r:refresh
```

This surface needs no server, so it stays readable while the runtime is down.

### Keeper detail

`Enter` from the list. Live context comes from the newest trace-matched
TurnRecord; missing, malformed, unreadable, usage-less, and prior-trace
observations stay distinct unavailable states rather than collapsing to zero.

```
 Keeper: code-reviewer
   Identity
   Name:                  code-reviewer
   Generation:            1
   Paused:                no
   Current Work
   Task:                  -
   Last Blocker:          -
   Live Context
   Context:               8.9%  ##--------------------  93213 / 1048576 tokens
   Observed:              2026-08-23T01:53:26
   Turn Ref:              trace-1787333553810-0001a#429
   Runtime Stats
   Total Turns:           429
   Total Tokens:          37669331
   Total Cost:            $3.7016
   Last Turn:             2026-08-23T01:53:26
  j/k:scroll  l:logs  m:message  Esc:back  Tab:next  q:quit  r:refresh
```

### Keeper logs

`l` from detail. The newest 200 physical rows from the keeper's dated metrics
store, spanning month boundaries and rotated day segments. Reads are bounded by
row count, not file size.

```
 Keeper Logs: sangsu  (85 entries)
   Time     Kind Channel   Msgs          In/Out       Lat      Cost  Work
   14:31:08 turn turn         7            10/12       0ms    $0.000  tool_use
   14:31:32 hb   hb          --            --/--        --        --
  j/k:scroll  Esc:back  q:quit  r:refresh
```

| Field | Meaning |
|-------|---------|
| Time | `HH:MM:SS` from the row timestamp |
| Kind | current `keeper.metrics.v1` Turn or Heartbeat row |
| Channel | canonical short label (`turn`, `sched`, `hb`) |
| Msgs | observed message count, `--` when the heartbeat did not observe it |
| In/Out | `input_tokens` / `output_tokens` from usage |
| Lat | observed `latency_ms`, including zero; `--` when unavailable |
| Cost | observed `cost_usd`, including zero; `--` when unavailable |
| Work | `work_kind` label |

Malformed JSON, current-schema decode failures, and storage failures are shown
rather than skipped. Rejected rows consume the 200-row window and are never
backfilled with older data. A current-schema row whose `name` does not match the
selected keeper is rejected instead of being attributed to it by file location.

### Keeper message

`m` from detail. Sends to the keeper over `POST /api/v1/keepers/chat/stream`
with a durable UUIDv7 request ID. The send runs in the background, so refresh
and navigation stay responsive while the turn runs.

```
 Message to: sangsu  (port 8935)
   [14:35:01] you:    hello, how are you?  [tui-019...]
   [14:35:03] sangsu: ...reply text...     [tui-019...]
   > type here_
  Enter:send  Esc:back  Ctrl-U:clear line
```

The pane opens on the keeper's durable transcript. A turn the keeper ran on
its own is drawn as what it did, not as a blank line: a `thinking` row with
the reasoning the server kept and a count of the steps it withheld, then a
`tools` block with one row per call - the finished glyph for a call that
returned, `✗` for one that returned an error, `·` for one the trace never
saw finish, each with its duration - and then whatever the turn said.

```
 [21:41:34] thinking
   (2 reasoning steps, content withheld)
 [21:41:34] tools
   ✓ masc_task_history · 32ms
   ✗ tool_execute · 1.2s
```

Only a request-correlated terminal keeper result is rendered as a reply.
Interrupted streams, protocol errors, rejected turns, and terminal outcomes
without visible text become explicit status or error rows; partial text is never
promoted to a successful reply. One request may be in flight at a time. Drafts
are retained per keeper while navigating.

A failed roster read blocks sending. When `.masc/keepers/` cannot be read
reliably, a stale entry may still name the target, so membership alone does not
authorize an external effect - the surface renders
`Keeper roster is unavailable` and the footer reads
`Enter:disabled (roster unavailable)`.

#### Dispatch fence

Before any POST the TUI writes a `prepared` recovery fence and requires the new
directory chain, the file, and the parent directory entry to be durably synced.
`prepared` means no process has durably claimed a POST. The sender then acquires
the cross-process dispatch lock, rechecks the exact identity, and advances the
fence to `dispatching` before crossing the network boundary. Only that lock
holder may POST, and it holds the lock until the main TUI has applied the result
and acknowledged its recovery mutation.

`dispatching` never authorizes a later POST. After a crash, cancellation, or
failed result-phase write, recovery only reads the exact operation. Only an
outcome-unverified result durably advanced to `replayable` may be claimed for
another exact-ID POST, and that replay claim first returns the fence to
fail-closed `dispatching`. A stale retry never recreates a missing `prepared`
fence: it goes through the serialized claim and stops if the fence was already
removed.

Once the stream proves server acceptance the fence becomes `accepted`. If
delivery then becomes uncertain, new sends are blocked and `Ctrl-R` polls the
exact durable operation until it settles - it does not mint a fresh ID or issue
another chat POST. A definitive pre-acceptance rejection advances the fence to
`rejected`, which is cleanup-only. Only the current pre-handler statuses `400`,
`401`, `403`, and `404` qualify as definitive; timeouts, conflicts, rate limits,
`5xx`, and unknown statuses stay outcome-unverified because an intermediary may
have forwarded the POST before returning them.

If a fail-closed `dispatching` fence repeatedly returns operation `404`, the TUI
stays blocked on purpose: it cannot prove whether the POST crossed the boundary,
and it offers no force-replay or force-clear shortcut. Verify the exact
operation and the runtime logs before an operator removes that fence. Clearing
it without that proof can permit overlapping work.

### Approvals

Operator approvals scoped to the acting actor.

```
 MASC Approvals (0/0, hidden 0, actor masc-tui)  10:55:48  [connected]
   (no pending approvals)
  j/k:move  y/y:confirm  n/n:deny  r:refresh  Tab:next  | Port: 8935
```

`y` and `n` post to `/api/v1/operator/confirm`. Selection is held by item
identity, so a refresh that reorders or drops items does not move the cursor
onto a different request.

### Board

Posts with their vote and comment counts. `Enter` opens the body.

```
 MASC Board (50)  10:44:52  [connected]
 >   p-687c6844e~  polisher     [B1 mission draft v9] RW20 PoC scenario     +9  c39
     p-0323d8b3c~  dashboard    RFC-0370 Draft: rotation census             +4  c22
  j/k:move  Enter:read  r:refresh  Tab:next  | Port: 8935
```

Selection follows post identity across refreshes. Opening a post binds the
detail view to that post's request, so a late response for a post you already
left is discarded rather than rendered under the current title.

`w` on the list opens a new-post draft. The draft follows the commit-message
convention: the first line is the title, the rest is the body. `Enter` makes
a new line, and sending is armed rather than pressed - `esc` offers
`s:send d:discard`, so no stray key publishes. The post goes out under the
operator's agent identity; the server stamps the author. A rejected post
keeps the draft and shows the server's message.

`v` votes the row under the cursor up, `V` votes it down - the shift key is
the direction. Like every irreversible action here, the first press arms and
the same press again sends. In a post, `c` replies: the same compose pane
opens with the post as its target, the whole draft is the comment, and
sending returns to the post with the reply visible.

### Planning

Goals with backlog rollups.

```
 MASC Planning  10:44:57  [connected]
   Executing: 3  Paused/Blocked: 1  Verifying: 0  Done: 24  Dropped: 22
   Backlog: todo=4  claimed=0  running=6  done=109  cancelled=37
 >   [dropped ] P1  Reduce all kidsnote service backlogs to 0
     [executi~] P1  Multi-Keeper real-world mission keeper-collab-e0-r7
  j/k:move  Enter:detail  r:refresh  Tab:next  | Port: 8935
```

The cursor tracks goal identity in visible order, so a refresh that reorders
goals keeps the same goal selected.

In a goal detail, `c` requests completion, `x` drops, `o` reopens. Each is
armed rather than pressed - the first press shows what the same key again
would send, any other key disarms - and the server owns the phase rules: a
transition the current phase does not allow comes back as the server's
rejection on the detail, not a local guess.

### System Logs

The server's log ring, the same source the dashboard `logs` tab reads.

```
 MASC System Logs (300 of 774273, seq 774272)  03:09:37  [connected]
   Time     Level Module           Keeper       Message
   03:09:21 INFO  Discord          system       presence update: idle
   03:09:18 WARN  Keeper           alpha        turn budget exceeded, deferring
   03:08:57 ERROR Board            system       board post write failed: ...
  j/k:scroll  Tab:next  q:quit  r:refresh  | Port: 8935
```

The header counts two different things. `300` is what this page holds; `774273`
is what the ring has seen. A page count on its own would read as "that is all
there is".

Levels are coloured: `ERROR` red, `WARN` yellow, `DEBUG` dim. A level the
server emits that this build does not name keeps its own text and renders
unstyled, so it shows up as itself rather than as an ordinary line.

When the load fails the previous page stays on screen under a red line saying
so. The count above it is then stale, not a fresh reading.

## Keybindings

Global, outside message input:

| Key | Action |
|-----|--------|
| `Tab` | Next surface: Overview -> Keepers -> Approvals -> Board -> Planning -> System Logs -> Overview |
| `2` | Jump to Keepers from anywhere |
| `r` | Force refresh |
| `q` | Quit |

Per surface:

| Key | Surface | Action |
|-----|---------|--------|
| `j` / `k` | Overview | Scroll Recent Events |
| `j` / `k` | Keepers, Approvals, Board, Planning | Move cursor |
| `j` / `k` | System Logs | Scroll the page |
| `j` / `k` | Keeper detail, logs, Board read, Planning detail | Scroll content |
| `Enter` | Keepers | Open keeper detail |
| `Enter` | Board | Open post body |
| `Enter` | Planning | Open goal detail |
| `l` | Keeper detail | Open logs |
| `m` | Keeper detail | Open message input |
| `y` / `n` | Approvals | Confirm / deny the selected request |
| `Esc` | any detail or logs view | Back one level |
| `Enter` | Message | Send |
| `Ctrl-R` | Message | Claim a prepared fence, reconcile a fail-closed fence, replay only a replayable fence, or remove a rejected or settled fence by exact durable ID |
| `Ctrl-U` | Message | Clear the input line |
| `Backspace` | Message | Delete the last UTF-8 scalar without splitting its byte encoding |

`Ctrl-R` stays available even when extra status rows leave the terminal too
small for normal message input.

## Navigation

```
Tab cycles the five surfaces:

  Overview -> Keepers -> Approvals -> Board -> Planning -> Overview

Within a surface:

  Keepers   --Enter-->  Keeper detail  --l-->  Keeper logs
                              |
                              m
                              v
                        Message input

  Board     --Enter-->  Board read
  Planning  --Enter-->  Goal detail
```

`2` reaches Keepers from any surface. `Esc` returns one level within Keepers,
Board, and Planning.

## Requirements

Interactive TTY stdin and stdout, and a terminal other than `dumb`.

Rendering is input-driven: a frame is produced after input, an applied refresh
or result, or a terminal resize. Background changes are coalesced into 16 ms
windows and only changed viewport rows are written. An idle TUI neither redraws
nor re-probes the terminal size.

Each non-empty paint is sent as one synchronized-output update (CSI 2026) so
terminals supporting the protocol reveal the frame atomically. `MASC_TUI_SYNC=off`
omits that envelope; row-diff correctness does not depend on protocol support.

Exit signals restore terminal modes and cursor state. Job-control suspension
(`Ctrl-Z`) restores the shell terminal, and `fg` re-enters raw mode and forces a
complete repaint.

Viewports below the fixed chrome budget render a compact resize gate instead of
a clipped frame, and message editing is suppressed until the terminal grows.

## Troubleshooting

**Header shows `[disconnected]`.** The server is not answering on
`127.0.0.1:<port>`. Keepers and the Tasks panel keep working; Approvals, Board,
Planning, and messaging do not. Check the port with `--port`.

**Keepers list is empty but the runtime is running.** The base path is probably
wrong. The list reads `.masc/keepers/` below `--base-path`, with no server
involved, so an empty list with no error means the directory is empty.

**Tasks panel prints `task backlog unavailable`.** The message carries the full
path, but it does not tell you whether the file is missing or malformed. A
missing key currently reads back as an empty JSON object, so an absent
`.masc/tasks/backlog.json` surfaces as the schema complaint
`backlog must contain exactly one tasks list, last_updated string, and positive
version`. Check that the path exists before treating it as a schema problem.

**A surface shows a count of `0` next to `data unreliable`.** The read failed;
the count is not an observation. The failing call is printed on the same row and
recorded in Recent Events.
