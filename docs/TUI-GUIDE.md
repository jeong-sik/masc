# MASC TUI Guide

Terminal UI for monitoring and interacting with MASC keepers.

## Quick Start

```bash
# Build
dune build bin/masc_tui.exe

# Run
./_build/default/bin/masc_tui.exe

# Or via start script
./start-masc-mcp.sh --tui
```

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

Press `Enter` on a keeper to see details.

```
Keeper: sangsu
Goal: keeper persona for Vincent
Model: llama:qwen3.5-35b-a3b-ud-q4-xl
Generation: 0 | Turns: 157
Context: N/A | Autonomy: L1_Reactive
Proactive: true | Initiative: board_only
Last seen: 2026-03-22T12:22:54Z

[Esc] Back  [q] Quit
```

## Keybindings

| Key | Action |
|-----|--------|
| `Tab` | Toggle Dashboard / Keeper mode |
| `j` / `Down` | Move cursor down (keeper mode) |
| `k` / `Up` | Move cursor up (keeper mode) |
| `Enter` | Open keeper detail |
| `Esc` | Back to list from detail |
| `q` | Quit |

## Data Source

The TUI reads directly from `.masc/perpetual-keepers/*.json` files. It works without the MASC server running. For real-time data (context_ratio, heartbeat), the server must be running.

## Requirements

- OCaml 5.x
- Dependencies: `unix`, `yojson` (no additional libraries)
- Terminal with ANSI escape support
