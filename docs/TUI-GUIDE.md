---
status: runbook
last_verified: 2026-08-22
code_refs:
  - bin/masc_tui.ml
  - bin/masc_tui_keeper_chat_projection.ml
  - bin/masc_tui_keeper_chat_recovery.ml
  - bin/masc_tui_render.ml
  - bin/masc_tui_loader.ml
---

# MASC TUI Guide

Terminal UI for monitoring and interacting with MASC keepers.

## Quick Start

```bash
# Build
dune build --root . bin/masc_tui.exe

# Run against the same shared runtime root as the server
MASC_BASE_PATH="/path/to/base" ./_build/default/bin/masc_tui.exe

# Or, if installed
masc-tui
```

If the server is using a different base path, pass `--base-path <path>` or export
`MASC_BASE_PATH` before launching the TUI. The fallback order is
`MASC_BASE_PATH` -> `cwd`.

## Modes

### Dashboard Mode (default)

Shows workspace status: agents, tasks, events, messages. Refreshes every 2 seconds.

```
MASC Dashboard (v2.128.0)
Workspace: default | Agents: 5 | Tasks: 3

  Agent          Status    Task
  local-alpha    busy      Validate swarm coverage
  local-beta     active    Inspect runtime health
  sangsu         active    (idle)

[Tab] Keeper Mode  [q] Quit
```

### Keeper Mode

Press `Tab` to switch. Shows all registered keepers with status.

```
MASC Keepers (5 registered)

  Name                   Gen  Paused        Turns  Current Task
> dm-keeper                2  no              128  task-42
  qa-ui-smoke              1  yes              31  -
  qa-surface               3  no              204  task-57
  qa-harness               1  no               89  -
  sangsu                   1  no            30317  -

[j/k] Navigate  [Enter] Detail  [Tab] Dashboard  [q] Quit
```

### Keeper Detail View

Press `Enter` on a keeper to see details. Live context comes from the newest
trace-matched TurnRecord; missing, malformed, unreadable, usage-less, and
prior-trace observations remain distinct unavailable states.

```
Keeper: sangsu

  Identity
  Name:                  sangsu
  Generation:            1
  Paused:                no

  Current Work
  Task:                  -
  Last Blocker:          -

  Live Context
  Context:               55.2%  ########-----------  70629 / 128000 tokens
  Observed:              2026-08-21T12:00:00
  Turn Ref:              trace-current#30317

  Runtime Stats
  Total Turns:           30317
  Total Tokens:          2046321197
  Compactions:           18

  Autonomy
  Autonomous Turns:      22023
  Text / Tool:           14457 / 7565
  Board / Mention:       1187 / 56

[j/k] Scroll  [l] Logs  [m] Message  [Esc] Back  [q] Quit
```

### Keeper Log View

Press `l` from detail view. Shows the newest 200 physical rows from the
Keeper's canonical dated metrics store, spanning month boundaries and rotated
day segments. Reads are tail-bounded by row count rather than file size.
Malformed JSON, current-schema decode failures, and storage/layout failures are
shown explicitly; rejected rows consume the 200-row window and are never
silently backfilled with older data. A current-schema row whose `name` does not
match the selected Keeper is rejected instead of being attributed to that
Keeper by its file location.

```
Keeper Logs: sangsu  (85 entries)

  Time     Kind Channel   Msgs          In/Out       Lat      Cost  Work
  14:31:08 turn turn         7            10/12       0ms    $0.000  tool_use
  14:31:32 hb   hb          --            --/--        --        --

[j/k] Scroll  [Esc] Back  [q] Quit
```

Fields displayed per entry:
- **Time**: HH:MM:SS from the timestamp
- **Kind**: current `keeper.metrics.v1` Turn or Heartbeat row
- **Channel**: canonical short label (`turn`, `sched`, or `hb`)
- **Msgs**: observed message count, or `--` when the Heartbeat did not observe it
- **In/Out**: input_tokens / output_tokens from usage
- **Lat**: observed latency_ms, including zero; `--` when unavailable
- **Cost**: observed cost_usd, including zero; `--` when unavailable
- **Work**: work_kind label

### Keeper Message View

Press `m` from detail view. Type a message and send it to the keeper via `POST /api/v1/keepers/chat/stream`. Each send uses a durable UUIDv7 request ID and runs in the background, so navigation and refresh remain responsive while the turn runs. The MASC server must be running for this feature.

```
Message to: sangsu  (port 8935)

  [14:35:01] you:    hello, how are you?  [tui-019...]
  [14:35:03] sangsu: ...reply text...       [tui-019...]

  > type here_

[Enter] Send  [Esc] Back  [Ctrl-U] Clear line
```

Only a request-correlated terminal Keeper result is shown as a reply. Interrupted streams, protocol errors, rejected turns, and terminal outcomes without visible text are rendered as explicit status/error rows; partial text is never promoted to a successful reply. One request may be in flight at a time.

Before the TUI issues a POST, it writes a `prepared` recovery fence and requires any newly created directory chain, the file, and the parent-directory entry to be durably synced. A `prepared` fence means no process has durably claimed a POST. The sender then acquires the cross-process dispatch lock, rechecks the exact identity, and advances the fence to `dispatching` before crossing the network boundary. Only that lock holder may POST, and it keeps the lock until the main TUI has applied the result and acknowledged its recovery mutation. `dispatching` never authorizes a later POST: after a crash, cancellation, or failed result-phase write, recovery only reads the exact operation. Only an outcome-unverified result that was durably advanced to `replayable` may be claimed for another exact-ID POST; that replay claim first returns the fence to fail-closed `dispatching`. A stale TUI retry never recreates a missing `prepared` fence: it goes directly through the serialized claim and stops if the fence was already removed. A visible-but-unconfirmed preparation or claim issues no POST and remains retryable with `Ctrl-R`; later phase writes occur only after the current POST result is known. The server treats an authorized serialized replay as idempotent only when both the operation input and authorized source identity still match. An identity change produces an idempotency conflict and keeps the fence instead of silently replacing it.

Once the stream proves server acceptance, the fence becomes `accepted`. If delivery then becomes uncertain, new sends are blocked and `Ctrl-R` polls the exact durable operation until it settles; it does not mint a fresh ID or issue another chat POST. A definitive pre-acceptance rejection first advances the fence to `rejected`, which is cleanup-only and can never authorize a POST or operation GET. Only the current pre-handler HTTP statuses `400`, `401`, `403`, and `404` qualify as definitive; timeout-like statuses, conflicts, rate limits, `5xx`, and unknown statuses stay outcome-unverified because an intermediary may have forwarded the POST before returning them. Fence removal also fsyncs its parent directory. If that cleanup is incomplete, the settled request gets a separate cleanup-pending state and `Ctrl-R` acquires the same dispatch lock before retrying only durable removal—zero POSTs and zero GETs. Other transient recovery failures keep the exact request identity blocked for reload instead of enabling a new send. `Ctrl-R` remains available even when extra status rows make the terminal too small for normal message input. Drafts are retained per Keeper while navigating.

If a fail-closed `dispatching` fence repeatedly returns operation `404`, the TUI deliberately remains blocked: it cannot prove whether the POST crossed the boundary and offers no force-replay or force-clear shortcut. Verify the exact operation and runtime logs before an operator removes that fence; clearing it without that proof can permit overlapping work.

## Keybindings

| Key | Mode | Action |
|-----|------|--------|
| `Tab` | All (except message) | Toggle Dashboard / Keeper mode |
| `j` / `Down` | Keeper list | Move cursor down |
| `k` / `Up` | Keeper list | Move cursor up |
| `Enter` | Keeper list | Open keeper detail |
| `j` / `k` | Detail / Logs | Scroll content |
| `l` | Detail | Open log view |
| `m` | Detail | Open message input |
| `Esc` | Detail | Back to keeper list |
| `Esc` | Logs / Message | Back to detail |
| `Enter` | Message | Send message |
| `Ctrl-R` | Message | Claim a prepared fence, reconcile a fail-closed dispatching/accepted fence, replay only a replayable fence, or remove a rejected/settled fence by exact durable ID |
| `Ctrl-U` | Message | Clear input line |
| `Backspace` | Message | Delete the last UTF-8 scalar without splitting its byte encoding |
| `r` | All (except message) | Force refresh |
| `q` | All (except message) | Quit |

The TUI renders only after input, an applied refresh/result, or a terminal
resize. Background changes are coalesced into a 16 ms frame window, while an
idle TUI neither redraws nor reruns the terminal-size probe.

## View Navigation

```
Dashboard <--Tab--> Keeper List
                       |
                     Enter
                       |
                  Keeper Detail
                    /       \
                   l         m
                  /           \
           Keeper Logs    Message Input
```

## Data Sources

| Feature | Source | Server Required |
|---------|--------|-----------------|
| Active task list | `.masc/tasks/backlog.json` | No |
| Keeper list/detail | current-schema `.masc/keepers/*.json` | No |
| Live context status | `<name>/turn-records/YYYY-MM/DD.jsonl` (strict newest trace-matched row) | No |
| Keeper logs | canonical `<name>/metrics/` dated store (newest 200 physical rows) | No |
| Goal planning | `GET /api/v1/dashboard/planning` | Yes |
| Actor-scoped approvals | `GET /api/v1/operator?view=summary&include_messages=0&include_keepers=0` | Yes |
| Send messages | request-correlated `POST /api/v1/keepers/chat/stream` SSE | Yes |

## Requirements

- OCaml 5.x
- Project opam dependencies, including `unix`, `yojson`, `eio`, `uucp`, and
  `uuseg`
- UTF-8 terminal with ANSI escapes and xterm Unicode-11-compatible cell-width
  behavior. ttyd `1.7.7-unknown` with its DOM renderer is the measured target;
  other ANSI terminals may differ for compound emoji cursor placement.
