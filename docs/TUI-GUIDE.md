---
status: runbook
---

# MASC TUI Guide

MASC TUI (`masc-tui`, launched automatically when you run `masc` on an
interactive terminal) is an OCaml 5.5 + Eio terminal interface over a running
MASC server. It is organized around **6 workspaces** (`1`–`6`), 1-hop entity
dives, a 2-pane categorized **Settings** overlay (`,`), and an event-driven
SSE + on-demand HTTP architecture with **zero idle timer polling**.

Header clocks and row timestamps use the terminal's local timezone offset.
Provider usage trends and 24h rollups follow server-reported UTC windows.

New here? The [install guide](INSTALL.md) and its
[first-conversation section](INSTALL.md#first-conversation-with-imp) walk from
install to your first Task and Board post.

## What can I do here

Press `?` anywhere in the TUI (or type `/help` in the composer) to open the
context-aware dynamic keymap help generated directly from the keymap SSOT
(`lib/masc_tui/keymap/keymap.ml`). You can also print the full static reference
table from a checkout with `bin/masc_tui_keys_doc_cli.exe`.

Press `Ctrl+K` to open the **Universal Command & Entity Palette** — filter across
all 9 sections (Commands, Workspaces, Keepers, Companies, Goals/Tasks, Board/Wiki,
Sandboxes, Settings Keys, and all 22 Slash Commands including `/theme`, `/lang`,
`/btw`, `/clear`, `/context`, `/restart`) and press `Enter` to execute or jump
directly. Use `Ctrl+G` to jump straight to any Keeper's chat, and `Ctrl+L` to
inspect or switch model runtimes.

## Quick Start

From an installed release, run `masc` (or `masc-tui` explicitly). For human
contributors building from source:

```bash
dune build --root . bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path /path/to/your/workspace
```

`.masc/` must live directly below `--base-path`. Point the TUI at the same
workspace root and port (`--port`, default `8935`) as the MASC server.

## Options

Run `masc-tui --help` for the exact CLI flags (`lib/masc_tui/app/cli_args.ml`):

| Flag | Default / Purpose |
|---|---|
| `--port <int>` | MASC server port (`1..65535`; default `8935`, falls back to `MASC_HTTP_PORT` / `MASC_PORT`) |
| `--host <host>` | MASC server host (default `127.0.0.1`, falls back to `MASC_HOST`) |
| `--url <http(s)://host[:port]>` | Full server base URL (no path or query) |
| `--base-path <path>` (`--base`) | Workspace base path containing `.masc/` (falls back to `MASC_BASE_PATH`, then cwd) |
| `--workspace <name>` | Workspace display label (defaults to basename of `--base-path`) |
| `--theme <midnight\|arcade\|paper\|mono>` | Color theme preset (default `midnight`) |
| `--lang <ko\|en>` | UI language (default `ko`) |
| `--no-auto-start` | Do not auto-start a local `masc` server when the port is offline |
| `--version` / `--build-commit` | Print executable version or embedded Git commit SHA and exit |
| `-h`, `--help` | Print usage and exit |

The legacy `--reasoning` and `--tool-view` startup flags were removed in v2.5
and exit with code `2`. Switch reasoning display at runtime with `Alt+T`, and
tool call detail with `Ctrl+O` or `/tools compact|results|full` (in Memory
Explorer, `Ctrl+O` opens the Formation Tree diagram).

## Navigation & Keybindings

MASC TUI is **monitor-first**: when the composer, filter box, or a text modal
is not focused, bare keys execute navigation and action shortcuts immediately.
All shortcuts come from `lib/masc_tui/keymap/keymap.ml`; VT100 control aliases
(`Ctrl+I`, `Ctrl+M`, `Ctrl+H`) are never bound.

### Core Navigation

| Key | Scope | Action |
|---|---|---|
| `1`–`6` (or `Ctrl+1`–`6`, `Alt+1`–`6`, `F1`–`F6`) | Unfocused / Global | Switch to workspace `1 Pulse`, `2 Work`, `3 Knowledge`, `4 Keepers`, `5 Runtime`, `6 Infra` |
| `[` / `]` (or `←` / `→` unfocused, `Alt+[` / `Alt+]`) | Unfocused / Global | Cycle sub-tabs (Workspaces, 5-tab Keeper Dive, Queue/Context drawer; inside the composer `←`/`→` move the text cursor, in Settings Tree they collapse/expand categories, and in Settings Inspector or Keeper Config they cycle enum/bool/numeric values while `[` / `]` switch tabs) |
| `↑` / `↓` or `j` / `k` | Unfocused / Overlay | Move list selection or scroll Keeper Chat |
| `PgUp` / `PgDn`, `Home` (`g`) / `End` (`G`) | Unfocused / Overlay | Page scroll or jump to top / bottom |
| `Tab` / `Shift+Tab` | Unfocused / Overlay | Cycle active focus panes on multi-pane views (omitted on single-pane views and narrow layouts; cycles tabs in Queue/Context, selection in Palette, or Tree / Inspector in Settings) |
| `Enter` | Unfocused | 1-hop Dive into selected entity (Keeper, Goal, Task, Verification, Board Thread, Wiki, Artifact, Memory Diff, Lane, Sandbox) |
| `Space` | Unfocused | Context toggle (expand/collapse group or succession chain, Wiki/Artifacts mode, Memory diff window, Verification view, Tasks status chip, log level filter, Keeper Chat turn details, Settings dry-run diff) |
| `/` | Unfocused / Settings / Incidents | Focus inline filter box (`↑`/`↓` move selection live, `Enter`/`Tab` apply & blur, `Esc` clear & blur; on views without a filter bar such as Pulse or Keeper Chat, focuses the composer with `/`) |
| `z` | Unfocused | Toggle detail pane zoom |
| `r` | Unfocused | Force refresh active view from server SSOT (triggers `force=1` probe on Runtime Quotas/Failover) |
| `n` | Unfocused / Settings | Create new item in current workspace (Board post, `#goals` proposal, Schedule, Connector, Repo, or new Keeper) |
| `o` | Unfocused / Settings | Open linked `http(s)` URL externally, open Artifact Viewer on Artifacts, or open local TOML in `$EDITOR` from Settings |
| `.` / `Ctrl+O` / `v` | Memory Explorer (Unfocused) | `.` opens the Pele 3-stage SVG card (with Mermaid fallback) for the selected evolution event/fact; `Ctrl+O` opens the Formation Tree (Pele Graph / `Memory_tree`); while a diagram is open, `v` cycles `Auto (Pele)` → `Mermaid` → `Tree`, `y` copies diagram source, `r` retries, and `Esc` closes |

### `Esc` vs `Ctrl+Q`

- **`Esc` never quits MASC TUI.** Pressing `Esc` walks back one layer at a time:
  1. Cancel inline field editing in Settings, or close an open overlay (Palette, Settings, Incidents, Queue/Context, Help, Inline Action modal, Media Viewer).
  2. Exit the `/` filter box or blur the bottom composer (`i`).
  3. In **Keeper Chat** with an active turn/stream running, send a turn-interrupt request (`Post_keeper_turn_interrupt`; `Ctrl+X` also interrupts directly).
  4. Pop one level off the dive stack back to the parent workspace.
  5. Restore the split layout when a panel is zoomed with `z`.
  6. Clear an active workspace filter query when at top level.
  7. Return the Work > Tasks & Schedules status chip to All.
- **`Ctrl+Q`** (or `/quit` in the composer, or a double `Ctrl+C`) exits MASC TUI
  cleanly. An externally started server (`masc start` / `masc setup`) keeps
  running; a local server auto-started and owned by this TUI session is stopped
  via `SIGTERM` on quit (use `/restart` in the composer to re-exec `masc-tui`
  while preserving a TUI-owned server).

### Global Overlays & Pickers

| Key | Slash Twin | Action |
|---|---|---|
| `Ctrl+K` | — | Universal Command & Entity Palette (strictly separated from Approvals) |
| `Ctrl+G` | `/keeper [name]` | Keeper/Chat quick switcher |
| `Ctrl+L` | `/model [lane]` | Runtime/Model switcher |
| `,` (unfocused), `Ctrl+,`, `Alt+,`, `F10` | `/config [query]` | 2-pane, 7-category **Settings** overlay |
| `Ctrl+T` | `/queue`, `/context` | 3-tab **Queue / Context / Schedules** drawer; the Context tab shows the selected Keeper's context fill per turn over its last 60 turns, and its latest compaction and history reset |
| `I` (unfocused), `Alt+I` | `/incidents` | Historical Incidents drawer (`d` dismiss, `c`/`D` clear all, `Space` show dismissed, `o`/`Enter` dive) |
| `J` (unfocused), `Alt+J` | `/jump` | Teleport to the highest-priority blocked item (Ask, Tool Approval, or Goal Confirmation) |
| `?` (unfocused) | `/help` | Dynamic keymap help overlay |

### Chatting with a Keeper

Because the TUI is monitor-first, typing bare letters before focusing the
composer dispatches navigation or overlay shortcuts (`1`–`6`, `,`, `I`, `?`,
`j`/`k`, etc.). To talk to a Keeper:

1. Press `4` (**Keepers**), select the Keeper with `↑`/`↓` (`j`/`k`), and press
   `Enter` to enter the 5-tab **Keeper Dive** (opens on **Chat & Stream**).
   - Shortcut: press `c` on a selected Keeper (or use `Ctrl+G`) to jump straight
     into Chat with the composer already focused.
2. Press `i` to focus the bottom composer.
3. Type your message (or paste directly — bracketed paste while unfocused also
   focuses the composer and inserts text cleanly):
   - **`Enter`** — Send message. While the Keeper is in a turn, the message waits in the queue (`Queued`) and runs after that turn ends; the running reply is not cut. When the `/` or `@` popup is open, `Enter` executes or inserts the highlighted item.
   - **`Alt+Enter`** or **`Ctrl+Enter`** — **Steer**: cut the reply to your own running request and send this message in its place. When the running turn is not one you sent (another Keeper's delegated request, an autonomous or scheduled turn), nothing is cut: the message is queued and a toast says so.
   - **`Shift+Enter`** or **`Ctrl+J`** — Insert a literal newline inside the composer.
   - **`/` or `@` popup** — Type `/` (command or argument completion) or `@` (Keeper mention) to open the interactive popup: `↑`/`↓` (`PgUp`/`PgDn`, `Home`/`End`) move selection, `Tab` completes, `Enter` executes or inserts, and `Esc` dismisses the popup while keeping the composer focused (second `Esc` blurs).
   - **`Ctrl+W`** / **`Alt+Backspace`** — Delete the previous word; **`Ctrl+U`** clears to line start; **`Ctrl+A`/`E`** jump to line start/end.
   - **`←` / `→` / `Home` / `End`** — Move the editing cursor inside the draft (`Ctrl+←/→` or `Alt+←/→` jump by word).
   - **`Esc`** — Dismiss open `/` or `@` popup first, then blur the composer while preserving your per-Keeper draft.
4. While reading Chat (unfocused):
   - **`Ctrl+O`** or **`/tools [compact|results|full]`** — Cycle or set tool call detail mode (in Memory Explorer, opens the Formation Tree diagram).
   - **`Alt+T`** — Cycle thinking/reasoning display (`folded` → `full` → `hidden`).
   - **`Ctrl+F`** — Cycle origin display mode (`bare` → `inline` → `row`).
   - **`Space`** — Toggle inline turn details.
   - **`Ctrl+X`** — Interrupt the active Keeper turn.
   - **`y`** — Copy the Keeper's latest reply to the clipboard via OSC 52.

### Mouse & Copy

- **Native terminal drag-select is ON by default** (`default_mouse_capture = false`
  in `lib/masc_tui/app/app.ml`). You can drag-select and copy text with your
  terminal's native mouse selection immediately without toggling anything.
- Press **`m`** (while unfocused, with no overlay or text input active) to
  toggle **mouse-wheel capture** ON/OFF:
  - When ON, scrolling the mouse wheel moves list selections and scrolls Keeper
    Chat (`Wheel_up` / `Wheel_down`).
  - Press **`m`** again to turn mouse capture OFF and return to native terminal
    drag-select.
- Press **`y`** (while unfocused) to copy the selected entity via **OSC 52**
  clipboard escape sequence:
  - **Keeper Chat**: latest assistant reply
  - **Board**: selected post body
  - **Wiki**: open page Markdown (or selected page slug)
  - **Artifacts / Media Viewer**: selected artifact SHA-256
  - **World Memory / Memory Diagram**: briefing text or top claim; when a Memory Diagram is open, copies its Mermaid source or Formation Tree text
  - **Sandboxes / Repos / Logs**: keeper name, repository URL, or log message
  - **Work / Runtime**: goal/task title, schedule ID, ask ID, candle keeper, or lane ID

  OSC 52 has no acknowledgement channel; terminal clipboard support depends on
  your terminal emulator (and `allow-passthrough` / `set-clipboard` inside
  `tmux`).

### Slash Commands

Type a `/` command in the focused composer and press `Enter`
(`lib/masc_tui/keymap/slash.ml`):

| Command | Action |
|---|---|
| `/pulse`, `/work`, `/knowledge`, `/keepers`, `/runtime`, `/infra` | Jump directly to the named workspace |
| `/keeper [name]` | Open Keeper switcher, or dive directly into `<name>`'s Chat |
| `/model [lane]` | Open Model/Runtime switcher, or inspect/dry-run `<lane>` in Settings |
| `/config [query]` | Open 2-pane Settings overlay (optionally pre-filtered by `<query>`) |
| `/incidents` | Open Historical Incidents drawer |
| `/jump` | Jump to highest-priority blocked item |
| `/voice` | Toggle Voice Push-to-Talk |
| `/btw <question>` | Ask an ephemeral side-query to the target Keeper without polluting chat history |
| `/queue`, `/context` | Open the Queue or Context tab of the Queue/Context drawer |
| `/tools [compact\|results\|full]` | Cycle or set tool call detail mode |
| `/clear` | Clear active composer draft and reset chat scroll (also clears active view filter when draft is empty) |
| `/theme [midnight\|arcade_hi\|paper_light\|mono]` | Cycle or set color theme preset (persisted via `/api/v1/tui/preferences`) |
| `/lang [ko\|en]` | Toggle or set UI language (persisted via `/api/v1/tui/preferences`) |
| `/help` | Open dynamic keymap help |
| `/restart` | Request graceful TUI restart (re-execs `masc-tui` while preserving owned server) |
| `/quit` | Quit MASC TUI cleanly |

### Korean IME Support

When your keyboard layout is set to Korean 2-set Hangul while **unfocused**
(navigation, Ask choices, or Approval Strip), single-key Latin shortcut mapping
(`Keymap.allows_ime_replay`) lets bare navigation keys continue to work without
switching input methods. Inside focused text inputs (composer, filter, modals),
Korean input is preserved verbatim.

## Surfaces: 6 Workspaces & Sub-Tabs

### `1` Pulse

The organization cockpit (`lib/masc_tui/screens_core/screen_pulse.ml`):

- **4-KPI Hero Band**: live fleet counts (`running/total`), 24h turn volume,
  sandbox infra mix (`vm · ssh · dk`), and 24h verification / spend summary.
- **Attention Queue**: live pending Asks, held Tool Approvals, Gate items, and
  Goal confirmations.
- **Group Overview**: Keepers grouped by `keeper.group` with 24h activity
  sparklines and health/spend rollups.
- **Goals, Scorecard & 24h World Pulse**: active Goals summary and workspace
  health snapshot.
- Selecting a Keeper row and pressing `Enter` dives straight into that Keeper's
  5-tab view.

### `2` Work

Four sub-tabs (`[` / `]` or `←` / `→`):

1. **Pipeline** (Goals & Verifications): side-by-side Goals list and
   Verification requests (`Tab` switches pane; `Enter` dives into Goal or
   Verification detail; `Space` toggles Verification view between `Pending` and
   `All`; `n` opens `#goals` proposal modal).
   - Goal hotkeys: `a` advance/approve (opens server-issued confirmation proof
     modal when `Awaiting_confirmation`), `c` request completion verification,
     `x` pause (or drop when already paused).
   - Verification hotkeys: `a` approve verdict, `x` reject modal.
2. **Tasks & Schedules**: workspace task backlog and scheduled automations
   (`Space` cycles the status chip All → Active → AwaitingVerify → Todo →
   Unlinked → Done → Schedules, `/` narrows by title or id within the chip,
   `Enter` dives into Task detail, `n` opens new Schedule form, `x` opens Task
   cancel modal).
   - Schedule form: target Keeper, repeat (`once`, or `every` with a delay
     such as `every 30m`), first run delay (`90s`, `10m`, `2h`, `1d`), and the
     prompt the Keeper is woken with. A repeat or delay in any other form keeps
     the form open with an error. Daily and cron schedules are created with
     `masc_schedule_create`, not from this form.
3. **Inbox** (Action Inbox): unified operator triage queue (see
   [Approvals](#approvals) below).
4. **Candle & Scorecard**: fleet Candle ledger (`GET /api/v1/candle/ledger`),
   policy/half-life status, Keeper balances, unattributed payout diagnostics,
   and group/fleet performance scorecard.

#### Approvals

Pending operator decisions appear in two places:

- **Fast Approval Strip**: whenever an actionable item is waiting (held Tool
  Approval, Gate request, Ask, or Goal confirmation), a 1-row strip appears
  above the composer on every workspace.
  - Unfocused: press **`Y`** to approve/accept (or select Ask choice 1) and
    **`N`** to deny/skip (opens reason modal for Gate rejection).
  - While typing in the composer: use **`Alt+Y`** and **`Alt+N`** without
    losing your draft.
  - A Tool Approval answer toasts what the server did with it: the waiting
    call took it, the call had stopped waiting and the answer applies when
    the same call is retried, or no call was waiting. In the last case
    nothing is recorded, the item stays, and the held approvals are read
    again.
  - For **Goal confirmations**, `Y` never fabricates proof tokens — it dives
    into **Goal Dive** so you can review verified proof and submit the exact
    server-issued `criterion_revision`, `request_id`, `verification_run_id`,
    and `operator_id`.
- **Action Inbox (`2 Work → Inbox`)**: press `J` (`Alt+J` or `/jump`) from
  anywhere to teleport to the highest-priority blocked item. When an Ask is
  focused, press **`1`–`4`** to submit choices `1`–`4` directly; in-flight
  submissions stay visibly tracked until acknowledged by the server.

### `3` Knowledge

Three sub-tabs (`[` / `]` or `←` / `→`):

1. **Board**: workspace posts with Signal-only vs All filtering and Succession
   Chain folding (`Space` expands/collapses a selected succession chain, or
   toggles Signal-only/All when no chain is selected; `Enter` opens Thread Dive;
   `n` opens new Board post modal; `y` copies selected post body).
2. **Wiki & Artifacts**: shared `.masc/wiki/` index, lint status, and published
   artifacts. Press **`Space`** to toggle between **Wiki** and **Artifacts**.
   - **Wiki mode**: `Enter` opens Wiki Dive (Markdown body, outgoing links,
     revision log), `e` opens inline Markdown edit modal (`PUT` with
     `expected_revision`/`expected_sha256`), `Ctrl+E` opens in `$EDITOR`, `y`
     copies Markdown body, `o` opens the first `http(s)` URL. A save toasts the
     revision it wrote, as a warning when the journal or index write failed,
     and the page is read again.
   - **Artifacts mode**: `Enter` opens Artifact Dive (title, summary,
     revision, MIME, size, SHA-256, author, created time, and the list of
     published artifacts), `o` opens the Media & Artifact Viewer overlay, `y`
     copies the body SHA-256 via OSC 52.
3. **Memory**: World Memory overview, Claims/Conflicts, Librarian writer status
   (`a` quick `resume`, `A` recovery act modal supporting `resume`, `adopt`,
   `restart_reading`, `skip_item`, `skip_line`), and the **Temporal Diff
   Scrubber** (`Space` cycles `24h` → `7d` → `30d`; `Enter` dives into
   `rev A..B` revision diff).

### `4` Keepers

Three fleet modes (`[` / `]` or `←` / `→`):

1. **Companies**: Keepers grouped by `keeper.group` (`Space` folds/unfolds the
   selected group).
2. **Attention**: triage-first ordering putting Keepers needing operator action
   or failing at the top.
3. **24h Wall**: fleet-wide 24-hour activity sparkline wall with turns and cost
   columns.

The **Ctx** column shows the context fill the server measured for the Keeper's
newest turn. `~42%` marks the server's estimate. A short word in its place
(`대화 누적` / `cumulative`, `기록 없음` / `no record`, ...) says why the turn has
no measured fill. Cost and tokens come from `keeper-costs` over the window
the label names (`24h`).

A Keeper whose TOML did not read shows as a red `✕ <name>: <error>` line under
the list instead of a row. Fix the TOML; the Keeper returns as a row on the
next roster refresh.

Press `n` on **Keepers** to open Settings targeted at creating a new Keeper.
Press `Enter` on any Keeper (or `c` to jump directly into Chat input) to open
the **5-tab Keeper Dive** (`[` / `]` cycles tabs):

1. **Chat & Stream**: live streaming conversation (`POST /api/v1/keepers/chat/stream`),
   per-Keeper durable drafts, pending-delivery states (`Queued`, `Sending`,
   `Pending_processing`, `Confirming_delivery`), tool/thinking/origin toggles,
   and turn interrupt (`Ctrl+X` or `Esc` during an active turn).
2. **Memory**: Keeper-scoped Temporal Diff (`24h`/`7d`/`30d`), **Retrieval
   Heat** stacked bar (`HOT`, `WARM`, `COLD`, `0x` never retrieved, total hit
   count), and Librarian recovery hotkeys (`a` resume, `A` recovery modal).
3. **Work & Candle**: Keeper's linked Tasks, Goals, and Candle balance/equipped
   portrait items.
4. **Sandbox**: Keeper's sandbox backend, network mode, agent socket, shim
   parity, 24h tool metrics, and on-demand probe (`p`).
5. **Config**: in-place editor of Keeper TOML fields (`keeper.group`,
   `activation_mode`, `sandbox_profile`, `mention_targets`, `board_interests`,
   etc.) with provenance and reload scope badges (`Hot_reload`, `Next_turn`,
   `Restart_required`). Navigate all fields with `↑`/`↓` (`j`/`k`), cycle
   enum/bool/numeric values directly with `←`/`→` (`h`/`l`), edit text or
   step fields with `Enter`, toggle booleans or preview a server-side dry-run
   diff with `Space`, save atomically with `Ctrl+S`, remove a key with
   `Delete`/`Ctrl+D`, filter with `/`, switch tabs with `[` / `]`, or press
   `e` to open the full Settings overlay. Works identically in both Keeper Dive
   and the `4 Keepers` split preview right pane.

### `5` Runtime

Four sub-tabs (`[` / `]` or `←` / `→`):

1. **Quotas & Credits**: provider quota windows, 7-day usage history, and
   unreported accounts toggle (`u`, or `Enter` on the unreported toggle row;
   `r` forces a fresh `runtime-probe`).
2. **Efficiency & Spend**: 4-KPI summary strip, 24h **Prompt Cache Hit Rate
   (%)** Braille chart, 24h dual-axis throughput/spend chart, and group/keeper
   cost efficiency table (live updates via view-scoped `models/metrics/stream`
   SSE).
3. **Failover Lanes**: ordered lane cascades (`Enter` opens Lane Dive), runtime
   probe reachability (`Space` toggles outside-lane probes, `r` forces probe),
   deduplicated **`exact_lane_runs`** (built-in exact-output and add-on exact
   lanes), and **Fusion** runs (`f` opens the Fusion launch modal).
4. **Tools & Connectors**: 24h tool metrics series (live updates via
   view-scoped `tool-metrics/series/stream` SSE), Tools catalog, Channel Gate
   Connectors (`n` opens the Connector bind form: connector name such as
   `discord`, channel ID, and the Keeper to bind), **Browser Lane** summary, and
   **Connected MCP Clients**.

### `6` Infra

Three sub-tabs (`[` / `]` or `←` / `→`):

1. **Sandboxes**: fleet inventory of MicroVM guests (presence, agent socket,
   shim parity, volume), SSH pools (reachability, active/max sessions), and
   Docker keepers (`Enter` opens Sandbox Dive inspector; `p` probes selected
   keeper or all).
2. **Repos & Changes**: registered repositories (`n` opens add-repo modal, `o`
   opens repository URL, `y` copies repository URL) and the selected
   repository's file-writing tool calls from the last 24 hours, with the
   recorded text in the preview pane. Calls the server could not read are
   counted in the changes card's subtitle.
3. **Activity & Logs**: unified live **System Logs** stream (view-scoped
   `logs/stream` SSE) + **Live Events** strip (`observer/stream` activity
   events) + structured key/value detail pane (`Space` cycles log level filter
   `All` / `ERR` / `WRN` / `INF`, `/` filters text, `y` copies selected log
   message, and `Stream_gap` pill surfaces any dropped events honestly).

### Global 2-Pane Settings Overlay (`,`)

Press `,` (or `Ctrl+,`, `Alt+,`, `F10`, or `/config [query]`) to open the
categorized TOML editor backed by `GET /api/v1/config/schema` and
`POST /api/v1/config/patch`:

- **Left Pane (Tree)**: 7 category groups (`1` General & UI, `2` Providers &
  Models, `3` Routing & Failover, `4` Keepers & Companies, `5` Sandbox & SSH,
  `6` Voice & Integrations, `7` Board, Memory & Candle). Navigate with `↑`/`↓`,
  expand/collapse with `←`/`→` (`h`/`l`), or jump directly with `1`–`7` /
  `[` / `]`.
- **Right Pane (Inspector)**: press `Tab` to focus fields; `←`/`→` (`h`/`l`)
  cycle enum, boolean, and numeric values directly (applying `tui.*` theme and
  language preferences live); `Enter` edits a field inline and stages the
  change; `Delete` or `Ctrl+D` toggles key removal; **`Space`** runs a
  server-side **dry-run diff** preview; **`Ctrl+S`** saves atomically and
  reports the effective reload scope (`hot_reload`, `next_turn`, or
  `restart_required`).
- **`Ctrl+E` or `o`**: escape hatch to edit local `runtime.toml` or an
  existing `<keeper>.toml` in `$EDITOR` (pauses and restores the terminal
  cleanly; unavailable for new-keeper creation, which must be submitted in
  Settings).
- **`n`** (on `4 Keepers & Companies` tab): begins creating a new Keeper TOML.

## Operator Tips & Practical Recipes

### Setting Keeper Groups (`keeper.group`)

Add an optional `group` string under `[keeper]` in
`<base-path>/.masc/config/keepers/<name>.toml`:

```toml
[keeper]
group = "platform"
```

For an existing Keeper, edit `keeper.group` directly in **4 Keepers → Dive →
Config** (or in the `4 Keepers` split preview Config tab: `↑`/`↓` to select,
`Enter` to edit, `Space` for dry-run diff, `Ctrl+S` to save via
`POST /api/v1/config/patch` with `target=keeper:<name>`, `next_turn` reload
scope), or edit `<base-path>/.masc/config/keepers/<name>.toml`. When creating
a new Keeper via `n` on **4 Keepers** (or the `4 Keepers & Companies` tab in
Settings `,`), you can set `keeper.group` directly in the creation form.

- Whitespace is trimmed; an absent or blank `group` maps to `"ungrouped"` on
  the server (in the TUI fleet list, Keepers without an explicit `keeper.group`
  fall back to a shared dash-prefix when two or more share one, otherwise
  `"Other"`).
- **Pulse**, **Keepers (`Companies` mode)**, and **Runtime → Efficiency &
  Spend** group Keepers by this label.
- `keeper.group` is purely a deployment-neutral display/grouping label; it is
  completely separate from `mention_targets` (Board `@mention` addresses) and
  `board_interests` (topic keywords for targetless Board discovery).

### Viewing & Editing Addon Lanes and Exact-Output Lanes

- **Configuration**: press `,` to open **Settings**, select category **`3`
  Routing & Failover** (or press `/` and search `addon_exact_lanes` /
  `exact_output_lanes`). The tree lists every `runtime.exact_output_lanes.<id>`
  (`Exact · <id>`) and `runtime.addon_exact_lanes.<id>` (`Addon · <id>`) table
  from `runtime.toml`. Edit fields with `Enter`, preview with `Space`, and save
  with `Ctrl+S`.
- **Runtime execution**: open **`5` Runtime → Failover Lanes** (`[ ]`) to view
  deduplicated recent **`exact_lane_runs`** alongside failover lane cascades
  and Fusion runs.

### Viewing Browser Lane Status

Open **`5` Runtime → Tools & Connectors** (`[ ]`). The right column renders the
**Browser Lane** summary card (`GET /api/v1/dashboard/browser-lane/clients`)
showing availability (`avail`), connected client count (`clients`), issue count
(`issues`), automatic-browse readiness (`auto`), and any diagnostic detail.

> **Current boundary:** Individual open browser tabs and interactive page
> readers are **not** listed inside TUI v2.6 yet. Use the Browser Lane CLI/tools
> or `masc browser-lane-setup` for tab-level operations.

### Viewing Memory Evolution

- **Workspace-wide**: open **`3` Knowledge → Memory**. Press **`Space`** to
  cycle the **Temporal Diff Scrubber** (`24h` → `7d` → `30d`) and press
  **`Enter`** to open a `rev A..B` revision-range dive. Inspect Librarian
  writer states and press `a` (quick `resume`) or `A` (recovery modal for
  `adopt`, `restart_reading`, `skip_item`, `skip_line`) when a writer is
  stopped.
- **Per-Keeper**: open **`4` Keepers → select Keeper → `Enter` → Memory** tab
  (`[ ]`). View that Keeper's scoped diff, **Retrieval Heat** stacked bar
  (`HOT` / `WARM` / `COLD` / `0x` hits), and per-Keeper Librarian recovery.
- **Pele / Mermaid / Formation Tree Diagrams** (in **`3` Knowledge → Memory**
  with a Keeper selected, or **`4` Keepers → Keeper → Memory**):
  - Press **`.`** on an evolution event (or ordinary fact linked to an evolution
    event) to open the **Pele 3-stage SVG card** (renders live Kitty/iTerm2
    pixels when supported, and falls back deterministically to `Mermaid` text
    otherwise).
  - Press **`Ctrl+O`** to open the **Formation Tree** (Pele Graph PNG or
    `Memory_tree` text fallback).
  - Inside an open diagram: press **`v`** to cycle `Auto (Pele)` → `Mermaid` →
    `Tree`, **`j`/`k`/`PgUp`/`PgDn`/`g`/`G`** to scroll text lines, **`y`** to
    copy diagram source, **`r`** to retry/refresh, and **`Esc`** to close.

### Viewing Unified Logs & Live Events

Open **`6` Infra → Activity & Logs**. The left pane streams live server logs
(`GET /api/v1/dashboard/logs/stream`) alongside the **Live Events** strip from
`observer/stream`; the right pane shows structured key/value details for the
selected entry. Press `Space` to cycle severity filters (`All` / `ERR` / `WRN`
/ `INF`), `/` to filter by text, and `y` to copy the selected log message.

### Viewing Artifacts

Open **`3` Knowledge → Wiki & Artifacts**, then press **`Space`** to switch
from Wiki to **Artifacts**. Press `Enter` for Artifact Dive (title, summary,
revision, MIME, size, SHA-256, author, created time, and the list of published
artifacts), `o` to open the **Media & Artifact Viewer** overlay, and **`y`** to
copy the **SHA-256** of the selected artifact's body via OSC 52.

> **Current boundary:** TUI v2.6 displays artifact metadata and copies SHA-256
> hashes; inline HTML rendering and full HTML/file content export or copy are
> **not yet implemented** in the TUI (use the web dashboard or HTTP API when
> you need rendered HTML or file download).

## Streaming vs On-Demand Architecture (Zero Idle Polling)

MASC TUI v2.6 enforces a strict connection budget in
`lib/masc_tui/store/subscriptions.ml` and `lib/masc_tui/store/update.ml`:

- **2 Persistent SSE Streams (`max_persistent_streams = 2`)** — open whenever
  the server is healthy and not gated:
  1. `Stream_observer`: `GET /mcp?sse_kind=observer` (dataset invalidations,
     heartbeats, turn completions, tool calls, approvals, board/memory/config
     notifications).
  2. `Stream_fleet`: `GET /api/v1/stream/fleet` (live fleet roster/status
     updates).
- **At Most 1 View-Scoped SSE Stream (`max_view_scoped_streams = 1`, total cap
  `max_streams = 3`)** — reconciled automatically whenever you switch workspace
  or sub-tab:
  - `5 Runtime → Efficiency & Spend`: `GET /api/v1/models/metrics/stream`
  - `5 Runtime → Tools & Connectors`: `GET /api/v1/tool-metrics/series/stream`
  - `6 Infra → Activity & Logs`: `GET /api/v1/dashboard/logs/stream[?since_seq=<n>]`
  - All other views run **0** view-scoped streams (only the 2 persistent
    streams).
  - When blocked by `Server_offline`, `Auth_gate`, or `Workspace_mismatch`,
    `Subscriptions.plan` returns `[]` (0 active streams).
- **Zero Idle HTTP Polling**: `Msg.Tick` (`lib/masc_tui/store/update.ml`) emits
  **zero** HTTP commands — it only updates the minute wall clock, expires
  toasts, and ticks elapsed seconds during active voice recording. Between
  minute boundaries with no incoming events, the UI loop (`Wake_bell`) sleeps
  at **0 Hz**.
- **On-Demand Fetches & Invalidation Refreshes**:
  - After `/health` succeeds, `View_fetches.bootstrap_fetches` loads core state
    plus the current view once.
  - Switching workspaces, sub-tabs, dives, or overlays fetches only missing or
    stale datasets required by that view (`View_fetches.fetches_for_current_view`).
  - `observer/stream` invalidation events (`Update_sse`) mark affected datasets
    stale and immediately re-fetch only global attention surfaces (approvals,
    asks, gate, keepers) or datasets visible in the currently active view.
  - Press **`r`** at any time to force-refresh the active view manually.

## Themes, Language, and Voice

- **Themes**: four WCAG 2.1 AA contrast-verified presets (`lib/masc_tui/core/theme.ml`):
  `midnight` (default), `arcade_hi` (CLI alias `arcade`), `paper_light` (CLI
  alias `paper`), and `mono`. Switch at runtime via `/theme [preset]` or at
  launch via `--theme`.
- **Language**: `ko` (default) or `en`. Switch at runtime via `/lang [ko|en]`
  or at launch via `--lang`.
- **Persistence**: runtime `/theme` and `/lang` changes persist to `[tui]` in
  `runtime.toml` over `POST /api/v1/tui/preferences` (requires a running MASC
  server; CLI flags apply session-only overrides).
- **Voice**: at boot, the TUI probes local audio capture (`rec` / `sox` /
  `ffmpeg`) and server voice endpoints (`/api/v1/voice/config`). Toggle
  Push-to-Talk with `V` (unfocused), `Ctrl+B`, `Alt+V`, `F8`, or `/voice`;
  transcribed text lands in the composer draft. See
  [VOICE-RUNBOOK.md](VOICE-RUNBOOK.md) for host setup.

## Server Connection & Auto-Start

TUI v2.6 communicates with the MASC server over HTTP/SSE. If `MASC_TOKEN` is
set in the environment, it is sent as a bearer token; otherwise the TUI reads
`<base-path>/.masc/auth/admin.token` when present.

- **Auto-start**: when `/health` fails with connection refused on initial boot
  (and `--no-auto-start` was not passed), the TUI attempts to start a local
  server once per session (`masc start --base-path <base> --host 127.0.0.1
  --port <port>`). That TUI-owned server is stopped via `SIGTERM` on `Ctrl+Q` /
  `/quit` (preserved across `/restart`), whereas a server started separately
  with `masc start` or `masc setup` stays running after the TUI exits. While
  offline, the `Server_offline` gate offers `s` (start local server), `r`
  (retry health), and `Ctrl+Q` (quit).
- **Workspace identity guard**: after `/health` returns the server's
  `instance_id` and `workspace_sha256`, every subsequent HTTP and SSE request
  enforces workspace parity. A `409 workspace_mismatch` halts streams and
  prompts you to verify `--base-path` / `--port` before pressing `r` to retry
  handshake.
- **No legacy `tui-keepers.toml`**: v2.5+ no longer reads or writes
  `tui-keepers.toml`; UI preferences live in `[tui]` via
  `/api/v1/tui/preferences`.

## Requirements

- Interactive TTY `stdin` and `stdout`, and `TERM` other than `dumb` (otherwise
  `masc-tui` exits with code `2`).
- Color depth is auto-detected from `COLORTERM` (`truecolor` / `24bit`) and
  terminfo (`Truecolor`, `Ansi256`, or `Ansi16`).
- Synchronized output (CSI 2026), bracketed paste, and Kitty keyboard protocol
  are negotiated cleanly and torn down on exit or `$EDITOR` handoff.
- Exit signals (`SIGINT`, `SIGTERM`) restore terminal raw mode, alt-screen, and
  cursor state. `SIGWINCH` dynamically resizes the frame; viewports below the
  minimum chrome budget display a **Micro Viewport Guard** that preserves
  drafts and accepts only `Ctrl+Q` until the terminal grows.

## Troubleshooting

**`masc` started a server instead of the TUI.** `masc` hands off to `masc-tui`
beside itself or on `PATH`. Release installs place both names together; a
source checkout builds `_build/default/bin/masc_tui.exe`, which does not match
`masc-tui`. Run `_build/default/bin/masc_tui.exe` directly or symlink both
binaries into `~/.local/bin` (see [README From source](../README.md#from-source)).

**The TUI does not show a change that is already on `main`.** The TUI is its
own binary. Rebuilding or restarting `bin/main_eio.exe` does not replace an
already-running TUI. Rebuild `bin/masc_tui.exe`, quit with `Ctrl+Q`, and
reopen — or use `scripts/tui-graceful-restart.sh --dry-run` followed by
`scripts/tui-graceful-restart.sh --build --base-path <dir>`.

**Why a TUI session ended.** Every session redirects stderr to
`.masc/logs/masc-tui-<pid>.log` under `--base-path` and writes a single final
exit line (`lib/masc_tui/core/exit_reason.ml`):

```text
[masc-tui] exit: normal (quit key)
[masc-tui] exit: normal (interrupt)
[masc-tui] exit: normal (signal SIGTERM)
[masc-tui] exit: abnormal (exception Failure("..."))
```

A normal exit comes from `Ctrl+Q` / `/quit` (`quit key`), a confirmed double
`Ctrl+C` (`interrupt`), or a terminate signal (`signal SIGTERM`, `EOF`). An
abnormal exit records the exception or `abnormal (no cause was recorded)`.
Summarize session exits with:

```bash
grep -h '\[masc-tui\] exit:' .masc/logs/masc-tui-*.log | sort | uniq -c | sort -rn
```

Sessions killed with `SIGKILL` or power loss run no release handler and write
no exit line.

**`Server_offline` gate appears.** Nothing is answering on `--host`:`--port`.
Press `s` to start a local server (or run `masc start --base-path <dir> --port
<port>`), check `.masc/logs/masc-server-<port>.log` if startup fails, and press
`r` to retry `/health`.

**`Auth_gate` appears.** The server requires bearer authentication and no valid
token was found. Export `MASC_TOKEN` or ensure `<base-path>/.masc/auth/admin.token`
is readable, then press `r` to retry.

**`Workspace_mismatch` halts streams.** The server listening on `--port`
belongs to a different workspace instance than the one established at boot.
Confirm the server's workspace via `curl -fsS 'http://127.0.0.1:8935/health?full=1' | jq '.paths'`,
re-point `--base-path` or `--port`, and press `r` to re-run handshake.

**A Keeper reply stops mid-stream.** When the chat stream drops after the
server accepted the message (network loss, an idle cut), the TUI posts the
same message again with the last event it received, and the reply continues
from there. It retries for about 30 seconds (after 1, 2, 4, 8 and 15 s), and
only while the server instance that accepted the message is still running.
After that the message shows as failed; the finished reply still appears in
Chat history once the Keeper's turn ends. A restarted server does not continue
the reply: the TUI checks the message against Chat history and shows it as
delivered or failed.

**A field or card shows loading, unreported (`—`), or failed instead of `0`.**
TUI v2.6 tracks every dataset with an explicit `Observed.t` state (`Loading`,
`Value`, `Absent`, `Unreported`, `Failed`) so missing or failed reads are never
fabricated as zero. Press `I` to inspect HTTP/SSE failure details in the
Historical Incidents drawer and `r` to force-refresh.
