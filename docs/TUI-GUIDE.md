---
status: runbook
last_verified: 2026-04-17
code_refs:
  - bin/masc_tui.ml
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
silently backfilled with older data.

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

Only a request-correlated terminal Keeper result is shown as a reply. Interrupted streams, protocol errors, rejected turns, and terminal outcomes without visible text are rendered as explicit status/error rows; partial text is never promoted to a successful reply. One request may be in flight at a time. If delivery becomes uncertain after submission, new sends are blocked and `Ctrl-R` polls the exact durable operation until it settles—never a fresh implicit retry or a second POST. Drafts are retained per Keeper while navigating.

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
| `Ctrl-R` | Message | Reconcile an outcome-unverified request by its exact durable ID |
| `Ctrl-U` | Message | Clear input line |
| `Backspace` | Message | Delete last character |
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
- Dependencies: `unix`, `yojson` (no additional libraries)
- Terminal with ANSI escape support
