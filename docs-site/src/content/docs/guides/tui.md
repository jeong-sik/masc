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
| **4** | **Memory** | Memory OS health and facts per Keeper (sorted by recency by default) | `Enter`: Fact browser, `c`: Cycle sort/category |
| **5** | **Approvals** | Gate queue, always-allow rules, and questions Keepers are waiting on | `a`: Approve, `d`: Deny |
| **6** | **Board** | Posts from operators, agents, automation, and system with rich feeds | `c`: Reply, `v`/`V`: Vote (+/-), `Y`: Copy link |
| **7** | **Planning** | Goals, plans, and multi-model deliberation (Fusion) | `v`: Walk Task Review, Verdicts, Schedules, Fusion |
| **8** | **Workspace** | Registered repositories and working-tree changes (`d`) | `Enter`: File browser, diffs, blame |
| **9** | **Runtime** | Runtime lanes, ordered candidate models, and provider reachability | `p`: Walk lanes |
| **10** | **Config** | Server runtime configuration (`e` edits in `$EDITOR`) | `s`: MCP resources, `t`: Tool catalog |

---

## Deep Surface Controls

### 1. Board Surface
Integrates post browsing, full discussion reading, and instant replying:

- **Action Chips**:
  - `[c] Reply`: Enters reply composer for the active post
  - `[v/V] Vote`: Upvote (`+1`, lowercase `v`) or downvote (`-1`, uppercase `V`)
  - `[Y] Copy Link`: Copies post URI (`masc://board/...`) to clipboard
  - `[Esc] Back`: Returns from thread read view to the post list
- **Rich Visual Metadata**:
  - **Hearth category chips**: Renders `#general`, `#dev`, `#alert` category tags in distinct theme tones
  - **Directional vote score**: Directional indicators such as `▲+3`, `▼-1`, or `0`
  - **Speech bubble reply counter**: `💬4` badge showing conversation activity
  - **Author role badges**: Distinguishes human operators (`@` [Author]) from autonomous Keepers (`◐` [Keeper])
  - **Threaded comment tree rails**: Indented comment hierarchy formatted with subtle rail lines (`│ `)

### 2. Keepers Detail & Instant Sandbox Backend Switching
Selecting any Keeper and pressing `Enter` opens the 9-tab detail inspection surface:

- **Tab Navigation**: Press `[` and `]` to navigate between tabs:
  - `Info` · `Sandbox` · `Settings` · `Secrets` · `GitHub` · `Automation` · `Runs` · `Channels` · `Identity`
- **Instant Sandbox Backend Switching**:
  - `d`: Instantly switch backend to **Docker** container isolation
  - `m`: Instantly switch backend to **MicroVM** hypervisor isolation
  - `s`: Instantly switch backend to **Remote SSH** worker host
  *(Directly dispatches configuration update and reloads the Sandbox view without editing raw files)*
- **Automation Tab**:
  - Real-time monitoring of active Keeper cron/interval schedules and execution timers.

### 3. Planning & Fusion Deliberation
Press `v` on the Planning surface to monitor multi-model Fusion deliberations:

- **Pipeline Stage Visualization**:
  - Renders deliberation progression through an ASCII diagram: `(pending) ➔ (in_progress) ➔ (completed)`.
- **Local Timezone & Caller Badges**:
  - Formats deliberation timestamps in your local timezone and displays caller identity badges.

### 4. Memory Surface
Inspect long-term memory facts extracted by Keepers:

- **Recency-first Default**: Displays latest learned facts and operational constraints first.
- **Sort/Filter Cycling**: Press `c` to cycle ordering:
  - `Recency` ➔ `Category` ➔ `Claim text`

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
