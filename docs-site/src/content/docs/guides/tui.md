---
title: Terminal UI (TUI) Guide
description: Surfaces, navigation keys, and operations in masc-tui.
---

`masc-tui` is the primary operator front door for observing and steering Keepers in the workspace.

## Launching

```bash
# Installed binary — pass the base path the server uses (a second terminal
# starts in your home directory, not the workspace)
masc-tui --base-path ~/masc --port 8935

# Or from a source checkout
dune build bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc --port 8935
```

When no server is answering on port 8935, pressing `s` on the Keepers surface launches a child server process immediately.

---

## The 10-Surface Ring

`Tab` and `Shift-Tab` rotate through the ring in this order:

| # | Surface | Primary Use | Children |
|:---:|---|---|---|
| **1** | **Overview** | Workspace summary, task backlog, and items needing attention | |
| **2** | **Activity** | Live newest-first feed of tool calls, turn boundaries, and settlements (`f` cycles scope) | `l`: Server system logs |
| **3** | **Keepers** | Roster, per-Keeper chat, tool call trees, sandbox status, and container logs | `f`: Changed files, `Enter`: Detail tabs |
| **4** | **Memory** | Memory OS health and facts per Keeper | `Enter`: Fact browser, `c`: Category filter |
| **5** | **Approvals** | Gate queue, always-allow rules, and questions Keepers are waiting on | `a`: Approve, `d`: Deny |
| **6** | **Board** | Posts from operators, agents, automation, and system | `c`: Create post/reply |
| **7** | **Planning** | Goals and plans | `v`: Walk Task Review, Verdicts, Schedules, Fusion |
| **8** | **Workspace** | Registered repositories and working-tree changes (`d`) | `Enter`: File browser, diffs, blame |
| **9** | **Runtime** | Runtime lanes, ordered candidate models, and provider reachability | `p`: Walk lanes |
| **10** | **Config** | Server runtime configuration (`e` edits in `$EDITOR`) | `s`: MCP resources, `t`: Tool catalog |

---

## Global Navigation Keys

| Key | Effect |
|---|---|
| `Tab` / `Shift+Tab` | Rotate through the 10 surfaces |
| `?` | Help overlay with all keybindings for the active surface |
| `:` | Command palette (`go <surface>`, `keeper <name>`, `settings`) |
| `/` | Live search across roster, code tree, or chat request tab |
| `r` | Force refresh |
| `q` twice | Quit TUI (leaves background server running) |

---

## Steering Keepers

The bottom input row sends instructions directly to the active Keeper:
- `/task <title>`: Calls `masc_add_task` to create a task and hands the Task ID to the Keeper.
- `/help`: Lists available slash commands (interrupt stream, switch Keeper, attach image).
- `masc_ask`: Answering interactive questions posed by the Keeper directly from the same row.
