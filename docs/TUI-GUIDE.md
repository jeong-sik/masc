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
MASC_BASE_PATH="$HOME/me" ./_build/default/bin/masc_tui.exe

# Or inspect the implicit home-scoped runtime (~/.masc)
./_build/default/bin/masc_tui.exe

# Or, if installed
masc-tui
```

If the server is using a different base path, pass `--base <path>` or export
`MASC_BASE_PATH` before launching the TUI. The fallback order is
`MASC_BASE_PATH` -> `HOME` -> `cwd`.

## Modes

### Dashboard Mode (default)

Shows room status: agents, tasks, events, messages. Refreshes every 2 seconds.

```
MASC Dashboard (v2.128.0)
Room: default | Agents: 5 | Tasks: 3

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

> dm-keeper        gen=0  model=qwen3.5  proactive=true
  qa-ui-smoke      gen=0  model=qwen3.5  proactive=true
  qa-surface       gen=0  model=qwen3.5  proactive=true
  qa-harness       gen=0  model=qwen3.5  proactive=true
  sangsu           gen=0  model=qwen3.5  proactive=true

[j/k] Navigate  [Enter] Detail  [Tab] Dashboard  [q] Quit
```

### Keeper Detail View

Press `Enter` on a keeper to see details. Includes live context status from metrics JSONL.

```
Keeper: sangsu

  Identity
  Name:                  sangsu
  Generation:            0

  Live Context
  Context:               55.2%  ########-----------  70629 / 128000 tokens
  Messages:              430

  Goals
  Goal:                  keeper persona for Vincent

  Model
  Active Model:          llama:qwen3.5-35b-a3b-ud-q8-xl

[j/k] Scroll  [l] Logs  [m] Message  [Esc] Back  [q] Quit
```

### Keeper Log View

Press `l` from detail view. Shows recent heartbeat/metrics entries from `<name>/metrics/YYYY-MM/DD.jsonl`.

```
Keeper Logs: sangsu  (85 entries)

  Time     Chan  Ctx        Tokens      In/Out   Lat    Cost    Work
  14:31:08  hb   55.2%  70629/128000  0/0        --      --    status_tick
  14:31:32  hb   55.2%  70629/128000  0/0        --      --    status_tick
  14:33:03  hb   55.2%  70629/128000  0/0        --      --    status_tick

[j/k] Scroll  [Esc] Back  [q] Quit
```

Fields displayed per entry:
- **Time**: HH:MM:SS from the timestamp
- **Chan**: channel (hb=heartbeat, turn, comp=compaction, hand=handoff, init=initiative)
- **Ctx**: context_ratio percentage with color coding (green < 50%, yellow 50-80%, red > 80%)
- **Tokens**: context_tokens / context_max
- **In/Out**: input_tokens / output_tokens from usage
- **Lat**: latency_ms (if > 0)
- **Cost**: cost_usd (if > 0)
- **Work**: work_kind label
- Guardrail stops are highlighted with a red STOP marker

### Keeper Message View

Press `m` from detail view. Type a message and send it to the keeper via `POST /api/v1/keepers/chat/stream`. The MASC server must be running for this feature.

```
Message to: sangsu  (port 8935)

  [14:35:01] you:    hello, how are you?
  [14:35:03] sangsu: ...reply text...

  > type here_

[Enter] Send  [Esc] Back  [Ctrl-U] Clear line
```

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
| `Ctrl-U` | Message | Clear input line |
| `Backspace` | Message | Delete last character |
| `r` | All (except message) | Force refresh |
| `q` | All (except message) | Quit |

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
| Keeper list/detail | `.masc/keepers/*.json` | No |
| Live context status | `<name>/metrics/YYYY-MM/DD.jsonl` (latest entry) | No |
| Keeper logs | `<name>/metrics/YYYY-MM/DD.jsonl` (last 200 entries) | No |
| Send messages | `POST /api/v1/keepers/chat/stream` | Yes |

## Requirements

- OCaml 5.x
- Dependencies: `unix`, `yojson` (no additional libraries)
- Terminal with ANSI escape support
