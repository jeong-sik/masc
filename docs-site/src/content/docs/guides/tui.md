---
title: Terminal UI (TUI) Guide
description: The masc-tui surfaces, navigation keys, and per-surface controls.
---

`masc-tui` is the primary entry point into a MASC workspace.

## Running it

```bash
# From an installed binary — pass the base-path the server uses
# (a fresh terminal starts in your home, not the workspace)
masc-tui --base-path ~/masc --port 8935

# Built from a source checkout
dune build bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/masc --port 8935
```

On the Keepers surface with no server connected, `s` launches the sibling `masc` binary and starts one. With a server connected, `s` shuts the selected keeper down.

Without a server, the keeper roster and the task backlog still render, read from `.masc/` on disk. Approvals, Board, Planning, Runtime, Memory, logs, and messaging need the server and say so instead of showing an empty list.

---

## What it looks like

Three of the surfaces, captured from a live runtime. Keeper names, task titles
and paths are stand-ins of the same width.

![Overview — one fleet status line, the Keepers needing attention, and the task list](/01-overview.png)

![Keepers — one row per Keeper with health, autoboot, sandbox, runtime and current task](/02-keepers.png)

![Activity — the newest-first feed of every Keeper's tool calls and turn boundaries](/06-activity.png)

## The surface ring

`Tab` and `Shift+Tab` rotate in this order, and the strip along the top row shows the same order.

| Surface | Shows | Entry to children |
|---|---|---|
| **Overview** | Workspace summary, the task backlog, what needs attention | |
| **Activity** | Every keeper's tool calls, turn boundaries, and settlements, newest first (`f` cycles scope) | `l`: system logs |
| **Metrics** | Three telemetry sections (`1` fleet & activity, `2` keeper memory resources, `3` gate queue) | `s`: cycle section |
| **Keepers** | The roster, chat, logs, tool calls, runtime, sandbox status and container logs, held secret names | `f`: changes, `Enter`: detail tabs |
| **Memory** | Memory OS health per keeper | `Enter`: the fact browser |
| **Approvals** | The gate queue, standing always-allow rules, and questions keepers ask a person | |
| **Board** | Posts from people, agents, automation, and the system | |
| **Planning** | Goals and plans | `v`: Goals · Task Review · Task Verdicts |
| **Fusion** | The panel/judge run list and detail | `Enter`: run detail |
| **Workspace** | Registered repositories, working-tree changes (`d`) | `Enter`: the code browser |
| **Runtime** | Runtime lanes, ordered candidates, provider reachability | `p`: lane detail |
| **Config** | `runtime.toml` as the server reads it (`e` edits), typed params, prompts, themes | `s`: MCP resources, `t`: tool catalog |

---

## Per-surface controls

### Approvals
Each queued ask draws on one row. `Enter` opens the full text of a multi-line argument (`j/k` scrolls, `Esc` goes back), then `y` confirms and `n` denies. `R` retries Auto Judge on a blocked row, and `e` cycles the external gate lane (manual / auto judge / always allow).

### Board
`w` writes a post; while reading, `c` replies. `v`/`V` vote up/down and `Y` copies the post reference. `s` cycles the sort (hot, trending, recent, updated, discussed) and `f` narrows to one sub-board. Threads indent along a vertical rail, and authors carry a person (`@`) or keeper (`◐`) badge.

### Keeper detail
`Enter` opens nine tabs, cycled with `[`/`]`: Info · Sandbox · Settings · Secrets · GitHub · Identity · Channels · Automation · Runs.

- On the **Sandbox** tab, `d`/`m`/`s` switch immediately to Docker, MicroVM, or Remote SSH. The switch posts straight through, with no config file edit.
- On the list: `c` chat, `l` logs, `t` tool calls, `u` pick a runtime lane, `g` toggle yolo/auto approval, `p`/`w` pause/wake, `s` shutdown.

### Planning and Fusion
Planning's `v` walks three tabs: Goals, Task Review, Task Verdicts. Goals is the goal lifecycle; the other two are the near and far halves of the Task protocol, so they are separate subjects rather than an order. Fusion is its own ring stop; `Enter` opens a run's detail. While a run is active its `STATE` shows the exact stage: `accepted`, `panel(N)`, `judge(A/F)`, `computed(A/F)`, `recording(A/F)`.

### Memory
`Enter` opens the fact browser. `c`/`C` cycles the category filter forward and backward, `s` changes the sort (recency, last retrieved, retrieved count, category, claim), `/` sets a live text filter with `n`/`N` stepping through matches, and `Esc` closes back to the health table.

### Workspace and reading code
In the code browser, `Enter` opens a file, `d` shows its diff against HEAD, `H` lists the commits that touched it, `b` puts blame in the margin, `m` shows notes anchored to it, and `K`/`D` ask the language server for hover text or the definition under the cursor.

---

## Waiting for the server

Start `masc-tui` before or just after the server and it holds on a waiting screen until `/health` answers, then enters the main surface.

---

## Global keys

| Key | Effect |
|---|---|
| `Tab` / `Shift+Tab` | Rotate surfaces |
| `?` | Every binding for the current surface |
| `:` | Command palette — `go <surface>`, `keeper <name>`, `settings` |
| `/` | Search — the keeper roster, the code tree, a chat's request tab |
| `r` | Force refresh |
| `q` twice | Quit |

Above the input row, every surface carries one line naming the next scheduled wake and whichever keeper is stopped waiting on a person. The line is absent when there is neither.

---

## The input row and slash commands

The input row sends a message to the keeper it names.

- `/task <title>` creates a task through `masc_add_task` and hands the keeper its id in the same message.
- `/help` lists the other slash commands: switching keepers, interrupting a streaming turn, staging an image.
- A question a keeper asked through `masc_ask` is answered from the same row.
