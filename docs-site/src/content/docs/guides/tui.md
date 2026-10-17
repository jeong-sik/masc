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

Without a server, the keeper roster and the task backlog still render, read from `.masc/` on disk. Approvals, Board, Work (Goals/Review/Verdicts), Runtime, Memory, logs, and messaging need the server and say so instead of showing an empty list.

---

## What it looks like

Three of the surfaces, captured from a live runtime. Keeper names, task titles
and paths are stand-ins of the same width.

![Overview — one fleet status line, the Keepers needing attention, and the task list](/01-overview.png)

![Keepers — one row per Keeper with health, autoboot, sandbox, runtime and current task](/02-keepers.png)

![Activity — the newest-first feed of every Keeper's tool calls and turn boundaries](/06-activity.png)

## The surface ring

`Tab` and `Shift+Tab` rotate through the 7-surface ring (`surface_ring`), and the strip along the top row shows the same order:

| Surface | Shows | Entry to children |
|---|---|---|
| **Dashboard** | Needs your decision, Continue conversation, Goal measurements, Task flow, and usage coverage | `p`: requests, `;`: Agenda, `m`: Usage |
| **Work** | Goals and Tasks (`t` switches), Task Review and Task Verdicts (`v` cycles), Approvals | `t`: Goals/Tasks, `v`: Goals · Task Review · Task Verdicts |
| **Keepers** | The roster, chat, logs, tool calls, runtime, sandbox status and container logs, held secret names | `f`: changes, `Enter`: 10 detail tabs |
| **Usage** | Provider quota scopes, Keeper costs and tokens, daily provider reports, and telemetry (`p`) | `p`: Telemetry (`1` fleet & activity, `2` keeper memory, `3` gate queue) |
| **Board** | Posts, replies, votes, attachments, and `alphatex`/`atex` tablature rendering | `Enter`: read post, `w`: compose |
| **Workspace** | Registered repositories, 24h clone activity (`H`), working-tree changes (`d`) | `Enter`: the code browser |
| **System** | `runtime.toml` (`e` edits), models, typed params, prompts, presets, themes, voice | `9`: Runtime (`p`: Lanes, `c`: Clients), `A`: Activity (`l`: Logs), `L`: Logs, `s`: Resources, `t`: Tools |

Additional surfaces (`Memory`, `Fusion`, `Approvals`, `Schedules`, `Lanes`, `Clients`, `Runtime`, `Browser Lane`, `Collab`, `MSX`, `DOS`, `Play links`) are opened via `:go <Name>` from the command palette, `&` for Collab, or `B` / `Ctrl-^` for Browser Lane.

---

## Per-surface controls

### Approvals
Open via `Work` or `:go Approvals`. Each queued ask draws on one row. `Enter` opens the full text of a multi-line argument (`j/k` scrolls, `Esc` goes back), then `y` confirms and `n` denies. `R` retries Auto Judge on a blocked row, `w` opens Workspace Gate modes, and `e` opens Outside services gate modes (manual / auto judge / always allow).

### Board
`w` writes a post (while composing, `Ctrl-A` attaches a local file); while reading, `c` replies. `v`/`V` vote up/down and `Y` copies the post reference. `s` cycles the sort (hot, trending, recent, updated, discussed) and `f`/`F` or `H` narrows to a sub-board (Hearth). On the read pane, pressing `1`–`9` opens or plays the numbered attachment under `ATTACHMENTS` (audio plays locally; MIDI renders through `fluidsynth` when `[tui] midi_soundfont` is set in `runtime.toml`), and fenced ```` ```alphatex ```` / ```` ```atex ```` blocks render as guitar tablature boxes. Threads indent along a vertical rail, and authors carry a person (`@`) or keeper (`◐`) badge.

### Keeper detail
`Enter` opens ten tabs, cycled with `[`/`]`: `Info · Items · Sandbox · Settings · Secrets · GitHub · Identity · Channels · Automation · Runs`.

- **Items** (one `]` after Info) lists the 18 portrait accessories by slot and Candle ownership.
- On the **Sandbox** tab, `d`/`m`/`s` switch immediately to Docker, MicroVM, or Remote SSH. The switch posts straight through, with no config file edit.
- On the list: `c` chat, `l` logs, `t` tool calls, `u` pick a runtime lane, `g` toggle persistent `yolo`/`auto` tool-approval mode (persisted across server restarts in the workspace gate root until switched back to `auto`), `p`/`w` pause/wake, `s` shutdown. Click a Keeper row to select it; click the selected row again to open its detail, as `Enter` does.

### Work (Goals, Task Review, Verdicts) and Fusion
Work's `v` walks three stops: Goals, Task Review, Task Verdicts. Goals is the goal lifecycle; the other two are the near and far halves of the Task protocol, so they are separate subjects rather than an order. Fusion is opened via `:go Fusion` (or the Keeper detail `Runs` tab); `Enter` opens a run's detail. While a run is active its `STATE` shows the exact stage: `accepted`, `panel(N)`, `judge(A/F)`, `computed(A/F)`, `recording(A/F)`.

### Memory
Open via `:go Memory`. `Enter` opens the fact browser. `c`/`C` cycles the category filter forward and backward, `s` changes the sort (recency, last retrieved, retrieved count, category, claim), `/` sets a live text filter with `n`/`N` stepping through matches, and `Esc` closes back to the health table.

### Workspace and reading code
In the code browser, `Enter` opens a file, `d` shows its diff against HEAD, `H` lists the commits that touched it, `b` puts blame in the margin, `m` shows notes anchored to it, and `K`/`D` ask the language server for hover text or the definition under the cursor.

---

## Waiting for the server

Start `masc-tui` before or just after the server and it holds on a waiting screen until `/health` answers, then enters the main surface.

---

## Global keys

| Key | Effect |
|---|---|
| `Tab` / `Shift+Tab` | Rotate the 7-surface ring (`Dashboard` → `Work` → `Keepers` → `Usage` → `Board` → `Workspace` → `System`) |
| `?` | Every binding for the current surface |
| `:` | Command palette — `go <surface>`, `keeper <name>`, `settings` |
| `&` / `Ctrl-^` (`B`) | Open Collab hub / Browser Lane reader |
| `/` | Search — the keeper roster, the code tree, a chat's request tab |
| `r` | Force refresh |
| `q` twice | Quit |

Above the input row, every surface carries one line naming the next scheduled wake and whichever keeper is stopped waiting on a person. The line is absent when there is neither.

---

## The input row, slash commands, and turn preparation

The input row sends a message to the keeper it names. While a turn is starting, the chat stream shows turn preparation details (context/memory assembly, runtime candidate selection, or queued `NEXT`/`STEER` position, with `Ctrl-K` to drop and `Ctrl-P` to edit the newest waiting line).

- `/features` opens the interactive feature sheet listing what the TUI can do along with the exact command or key for each entry.
- `/task <title>` creates a task through `masc_add_task` and hands the keeper its id in the same message.
- `/listen` toggles continuous voice capture and transcription for the selected keeper.
- `/queue` inspects the selected keeper's server queue inventory, and `/queue clear` clears the waiting local/server queue entries for that keeper.
- `/help` lists the other slash commands: switching keepers, interrupting or steering a streaming turn, staging an image, and issuing `/play` invites.
- A question a keeper asked through `masc_ask` is answered from the same row.
