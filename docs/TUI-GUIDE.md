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
Sandboxes, Settings Keys, and all 31 Slash Commands including `/ctl`, `/gate`,
`/exec`, `/skill`, `/prompt`, `/preset`, `/lane`, `/addon`, `/browser`, `/theme`,
`/lang`, `/btw`, `/clear`, `/context`, `/restart`) and press `Enter` to execute or jump
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
| `--version` | Print executable build version with embedded 8-char Git commit SHA (e.g. `0.81.0 (2a58dc57)`) and exit |
| `--build-commit` | Print full embedded 40-char Git commit SHA and exit (exits `1` if unembedded) |
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
| `b` / `Ctrl+B` / `Alt+B` | Unfocused / Global | Toggle or focus the **Collapsible Left Navigation Sidebar** (auto-docked when `cols >= 132`, floating drawer overlay when `cols < 132`): lists all 6 workspaces, every 1st-class sub-tab (including `Work → Harness` and `Infra → Code`), Fleet + specialized Keeper tabs (`Context & Turns`, `Tool Calls`, `Logs`, `Identity`; all 9 Keeper tabs via `[` / `]` in Keepers pane 1 / Dive), and System overlays (31 targets; `↑`/`↓`/`j`/`k` live-preview, `Enter`/`→`/`l` focus body, `Tab`/`Shift+Tab` unified focus ring, `Esc` return to main pane) |
| `1`–`6` (or `Ctrl+1`–`6`, `Alt+1`–`6`, `F1`–`F6`) | Unfocused / Global | Switch to workspace `1 Pulse`, `2 Work`, `3 Knowledge`, `4 Keepers`, `5 Runtime`, `6 Infra` |
| `7` / `8` / `9` / `0` | Unfocused | Quick utility overlays: `7` Settings (`,`), `8` Incidents (`I`), `9` Queue/Context (`Ctrl+T`), `0` Help (`?`) — never hijack focused text inputs |
| `←` / `→` | Unfocused | Spatial pane movement ONLY: move between Left Navigation Sidebar ↔ Pane 0 ↔ Pane 1 across every workspace and dive (never cycles sub-tabs; inside text inputs moves cursor; in Settings Tree collapses/expands categories; in Settings Inspector / Keeper Config cycles enum/bool/numeric values) |
| `[` / `]` (or `Alt+[` / `Alt+]`) | Unfocused / Overlay / Global | Cycle sub-tabs ONLY (Workspaces, 9-tab Keeper Dive or Keepers split right pane, Settings tabs, Queue/Context drawer, and multi-question Ask modal) |
| `↑` / `↓` or `j` / `k` | Unfocused / Overlay | Move list selection or scroll Keeper Chat |
| `PgUp` / `PgDn`, `Home` (`g`) / `End` (`G`) | Unfocused / Overlay / Composer (`PgUp`/`PgDn`) | Scroll by page or jump to the top or bottom. With the composer focused, `PgUp`/`PgDn` scroll the active view while preserving the draft. In `Infra → Code`, `g` cycles Git views and `Home` jumps to the top. |
| `Tab` / `Shift+Tab` | Unfocused / Overlay | Cycle active focus panes on multi-pane views (including `Goal_dive` Linked Tasks ↔ Verifier Runs and `Task_dive` Description ↔ Verification; omitted on single-pane views and narrow layouts; cycles tabs in Queue/Context, questions in multi-question Ask modal, selection in Palette, or Tree / Inspector in Settings) |
| `Enter` | Unfocused | Open the **Ask Answer Modal** on pending Asks (`Pulse` / `Work → Inbox`), toggle OAuth on `Keeper → Identity`, 1-hop Dive into selected entity (Keeper, Goal, Task, Verification, Board Thread, Wiki, Artifact, Memory Diff, Fusion Run, Tool Detail, Lane, Sandbox, Runtime Trace, Log Detail), dive from `Goal_dive` Linked Tasks / Verifier Runs directly into `Task_dive` / `Verification_dive` (or from `Task_dive` Verification into `Verification_dive`), or expand/open files, catalog packages, Facts Tree categories, Provider Input Parts, and Tool Results |
| `Space` | Unfocused / Overlay | Strictly safe local view/expand/selection toggle — **never sends a network POST** (Work > Goals phase filter All/Active/Verifying/Held/Closed, Board succession chain expand/collapse, Tasks status chip, Addons & Browser Clients/Tabs subfocus, Failover external probes, log level filter, Keeper Chat turn details, multi-select Ask choice toggle, local bool toggle in Settings/Keeper Config; dry-run diff is explicit `d`, Keeper Identity OAuth toggle is `a` / `Enter`) |
| `v` | Unfocused | Cycle view mode (Artifacts Doc vs Raw, Verification Dive Evidence/Summary/Specs/TLC, Knowledge Memory Diff/Health & Ledger/Context, Keeper Memory Diff/Health/Facts Tree/Journal, Keeper Context sub-tabs, Keeper Logs Metrics vs Sandbox Logs, Runtime Tools Usage/Catalog/Skills, Work Pipeline verification filter) |
| `/` | Unfocused / Settings / Incidents | Focus inline filter box or in-document search inside Artifact Dive (`n`/`N` step matches; `↑`/`↓` move selection live, `Enter`/`Tab` apply & blur, `Esc` clear & blur; on views without a filter bar such as Pulse or Keeper Chat, focuses the composer with `/`) |
| `z` | Unfocused | Focus the current Keeper detail tab by hiding the menu and secondary status badges. Press `z` again to restore the layout or `b` to open the menu. On the Keepers and Knowledge workspaces, toggle the preview pane zoom. |
| `r` | Unfocused | Force refresh active view from server SSOT (triggers `force=1` probe on Runtime Quotas/Failover) |
| `n` | Unfocused / Settings | Create new item in current workspace (Board post, `#goals` proposal, Schedule, Connector bind, Repo, or new Keeper; inside Artifact Dive with active search, steps to next match) |
| `o` | Unfocused / Settings | Open linked `http(s)` URL externally (Repos, Wiki, Browser Lane tabs), export & open HTML/Markdown artifact in the default browser on Artifacts / Artifact Dive / Media Viewer, or open local TOML in `$EDITOR` from Settings |
| `.` / `Ctrl+O` / `v` | Memory Explorer (Unfocused) | `.` opens the Pele 3-stage SVG card (with adaptive Mermaid fallback) from any keeper-scoped Memory subview (`Diff/Flow`, `Facts Tree`, `Journal`, `Health`, `Context`) and compact widths for a matching journal event. With no journal event or fact selected, `.` opens nothing and reports it. `Ctrl+O` opens its Formation Tree (Pele Graph / `Memory_tree`). An ordinary fact outside the loaded activity window opens as a single current fact in both views. While a diagram is open, `v` cycles `Auto (Pele)` → `Mermaid` → `Tree`, `y` copies diagram source, `r` retries, and `Esc` closes back to the prior subview |

### `Esc` vs `Ctrl+Q`

- **`Esc` never quits MASC TUI.** Pressing `Esc` walks back one layer at a time:
  1. Exit free-text editing inside the Ask Answer Modal (preserving the typed draft), cancel inline field editing in Settings, or close an open overlay (Palette, Settings, Incidents, Queue/Context, Ask Answer Modal, Help, Inline Action modal, Media Viewer).
  2. Exit the `/` filter box or blur the bottom composer (`i`).
  3. In **Keeper Chat** with an active turn/stream running, send a turn-interrupt request (`Post_keeper_turn_interrupt`; `Ctrl+X` also interrupts directly).
  4. Pop one level off the dive stack back to the parent workspace (restoring the exact previous focus pane and zoom state).
  5. Restore the split layout when a panel is zoomed with `z`.
  6. Clear an active workspace filter query when at top level.
  7. Return the Work > Tasks status chip or Work > Goals phase filter to All.
- **`Ctrl+Q` (pressed twice within 2.5 seconds)** (or `/quit` in the composer, or a double `Ctrl+C`) exits MASC TUI
  cleanly — the first `Ctrl+Q` arms quit with a warning toast, any other key cancels the arm, and pressing `Ctrl+Q` again within 2.5 seconds exits. An externally started server (`masc start` / `masc setup`) keeps
  running; a local server auto-started and owned by this TUI session is stopped
  via `SIGTERM` on quit (use `/restart` in the composer to re-exec `masc-tui`
  while preserving a TUI-owned server).

### Global Overlays & Pickers

| Key | Slash Twin | Action |
|---|---|---|
| `Ctrl+K` | — | Universal Command & Entity Palette (strictly separated from Approvals) |
| `Ctrl+G` | `/keeper [name]` | Keeper/Chat quick switcher |
| `Ctrl+L` | `/model [lane]` | Runtime/Model switcher |
| `7` / `,` (unfocused), `Ctrl+,`, `Alt+,`, `F10` | `/config [query]` | 2-pane, 7-category **Settings** overlay (header shows running TUI & Server build version/commit) |
| `9` (unfocused), `Ctrl+T` | `/queue`, `/context` | 3-tab **Queue / Context / Schedules** drawer (`[`/`]` or `Tab` switches tabs); the Context tab shows the selected Keeper's context fill per turn over its last 60 turns, and its latest compaction and history reset |
| `8` / `I` (unfocused), `Alt+I` | `/incidents` | Historical Incidents drawer (`d` dismiss, `c`/`D` clear all, `Space` show dismissed, `o`/`Enter` dive) |
| `J` (unfocused), `Alt+J` | `/jump` | Teleport to the highest-priority blocked item (for an Ask, jumps to `Work → Inbox` focused on that Ask and opens the **Ask Answer Modal** immediately) |
| `0` / `?` (unfocused) | `/help` | Dynamic keymap help overlay (top bar shows TUI & Server build version/commit and flags commit mismatch) |

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
   - **`Ctrl+T` → Queue** reads the selected Keeper's queued chat operations from the server, including submissions from other sessions. The drawer shows a separate entry for a local transmission until its operation appears in the server queue. A failed read displays its error. After a stream disconnect, the TUI looks up the original operation to confirm its state. If the Keeper reports that this exact ID has no status record, the message stays visible with its ID and can be dismissed with `X`. A later matching receipt can still update it. Sending the text again creates a new request.
   - **`Shift+Enter`** or **`Ctrl+J`** — Insert a literal newline inside the composer.
   - **`/` or `@` popup** — Type `/` (command or argument completion) or `@` (Keeper mention) to open the interactive popup: `↑`/`↓` (`PgUp`/`PgDn`, `Home`/`End`) move selection, `Tab` completes, `Enter` executes or inserts, and `Esc` dismisses the popup while keeping the composer focused (second `Esc` blurs).
   - **`Ctrl+W`** / **`Alt+Backspace`** — Delete the previous word; **`Ctrl+U`** clears to line start; **`Ctrl+A`/`E`** jump to line start/end.
   - **`←` / `→` / `Home` / `End`** — Move the editing cursor inside the draft (`Ctrl+←/→` or `Alt+←/→` jump by word).
   - **`PgUp` / `PgDn`** — Scroll the Keeper Chat transcript (or underlying scrollable view) without leaving the composer or losing your draft/cursor.
   - **`Esc`** — Dismiss open `/` or `@` popup first, then blur the composer while preserving your per-Keeper draft.
4. While reading Chat (unfocused):
   - **`Ctrl+O`** or **`/tools [compact|results|full]`** — Cycle or set tool call detail mode (in Memory Explorer, opens the Formation Tree diagram).
   - **`Alt+T`** — Cycle thinking/reasoning display (`folded` → `full` → `hidden`).
   - **`Ctrl+F`** — Cycle origin display mode (`bare` → `inline` → `row`).
   - **`Space`** — Toggle inline turn details.
   - **`Ctrl+X`** — Interrupt the active Keeper turn.
   - **`y`** — Copy the Keeper's latest reply to the clipboard via OSC 52.

### Inline Forms

Use `Tab` to move between fields and `Enter` to submit. In text bodies such as
Board posts, Wiki pages and operator notes, press `Shift+Enter` or `Ctrl+J` to
insert a line break. Pasting multiple lines preserves their line breaks.

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
  - **Artifacts / Artifact Dive / Media Viewer**: `y` copies full raw HTML/Markdown body via OSC 52 (fetching `GET /api/v1/published-artifacts/<id>` on demand if not yet cached); `H` copies SHA-256; `e` saves locally as `.html`/`.md` to `$HOME/Downloads/masc-artifacts/` (or `<base-path>/.masc/exports/` if `Downloads` is absent); `o` exports and opens the file in your default browser
  - **World Memory / Memory Diagram**: briefing text or top claim; when a Memory Diagram is open, copies its Mermaid source or Formation Tree text
  - **Sandboxes / Repos / Logs**: keeper name, repository URL, or selected log message / MASC event detail
  - **Work / Runtime**: goal/task title, schedule ID, ask ID, candle keeper, lane ID, addon instance ID, or selected browser tab URL

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
| `/ctl <action> [keeper]` | Keeper lifecycle & context control (`boot`, `shutdown`, `pause`, `resume`, `reset`, `clear`, `directive`, `note`, `run-next`, `checkpoints`) — destructive actions prompt 2-step confirmation |
| `/gate <subcmd>` | HITL Gate & Always-Approve operator controls (`rules`, `mode`, `external-mode`, `del-rule`, `approve-always`, `retry`, `keeper-mode`, `ack-uncertain`, `restore-late`) |
| `/exec <tool> [args_json]` | Invoke an MCP tool directly via stateless MCP `2026-07-28` (`POST /mcp`) |
| `/skill <subcmd>` | Skill catalog & SKILL.md editor (`refresh`, `new`, `read`, `edit`, `delete`) |
| `/prompt <subcmd>` | System prompt overrides & runtime params (`set`, `clear`, `param-set`, `param-clear`) |
| `/preset <subcmd>` | Workspace preset management (`list`, `show`, `save`, `create`, `restore`, `delete`) |
| `/lane <subcmd>` | Runtime lane CRUD, exact-lane candidate reorder, run inspection, raw preview & quarantine recovery (`create`, `remove`, `rename`, `set`, `exact-append`, `exact-drop`, `exact-move`, `exact-replace`, `run`, `quarantines`, `recover`, `raw-preview`) |
| `/addon <subcmd>` | Lane Add-on operator controls (`attach`, `detach`, `observe`, `retain`, `act`, `evidence`, `decl-read`, `decl-new`, `slice`, `asks`, `answer`, `operator`) |
| `/browser <subcmd>` | Browser (Ego) operator controls (`scene`, `screenshot`, `interact`, `command`) |
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

Six 1st-class sub-tabs (`[` / `]`, and Left Navigation Sidebar `b`):

1. **Goals** (Goals & Verifications): side-by-side Goals list and
   Verification requests (`Tab` switches pane; `Space` cycles the Goals phase
   filter All → Active → Verifying → Held → Closed; `S` cycles Goals sort
   Phase → Progress → Recent; `Enter` dives into Goal or Verification detail;
   `v` toggles Verification view between `Pending` and `All`; `n` opens `#goals`
   proposal modal). Inside **Goal Dive**, use `Tab` / `←` / `→` to switch
   between **Linked Tasks** and **Verifier Runs & Evidence**, `↑`/`↓` to select
   any linked task or verifier run, and `Enter` to dive straight into
   **Task Dive** or **Verification Dive**.
   - Goal hotkeys: `a` advance/approve (opens server-issued confirmation proof
     modal when `Awaiting_confirmation`, resumes when `Paused`, unblocks when
     `Blocked`, reopens when `Completed`/`Dropped`), `c` request completion
     verification (when `Executing`), `x` pause (or opens the drop-reason modal
     when already `Paused`).
   - Verification hotkeys: `a` approve verdict, `x` reject modal (both guarded
     locally when already resolved or superseded), `h` / `X` context-aware
     harness overrule modal (auto-fills a linked 64-hex `notes_hash` and places
     the cursor on `reason`, or warns if no valid verdict is linked). Inside
     **Verification Dive**, press `v` to switch between **Evidence**
     (`GET /api/v1/verification/evidence`, with explicit `CanAdmin` notice on
     401/403), **Summary** (`/api/v1/verification/summary`), **Specs**
     (`/api/v1/verification/specs`), and **TLC Results**
     (`/api/v1/verification/tlc-results`).
2. **Tasks**: workspace task backlog (`Space` cycles the status chip
   All → Active → AwaitingVerify → Todo → Unlinked → Done, `/` narrows by title
   or id within the chip, `Enter` dives into Task detail, `n` opens new
   Schedule form, `x` opens Task cancel modal, `h` / `X` opens harness overrule
   modal).
3. **Schedules**: dedicated 1st-class scheduled automations list (always
   reachable even when tasks or schedules are empty; `n` opens new Schedule
   form).
   - Schedule form: target Keeper, repeat (`once`, or `every` with a delay
     such as `every 30m`), first run delay (`90s`, `10m`, `2h`, `1d`), and the
     prompt the Keeper is woken with. A repeat or delay in any other form keeps
     the form open with an error. Daily and cron schedules are created with
     `masc_schedule_create`, not from this form.
4. **Inbox** (Action Inbox): unified operator triage queue (see
   [Approvals](#approvals) below).
5. **Candle & Scorecard**: fleet Candle ledger (`GET /api/v1/candle/ledger`),
   policy/half-life status, Keeper balances, unattributed payout diagnostics,
   and group/fleet performance scorecard.
6. **Harness** (Harness Health): live evaluator calibration metrics, pre-compact
   / handoff / verdict health, and selected verdict detail (`GET /api/v1/dashboard/harness-health`)
   including exact 64-hex `notes_hash`. Press `y` (approve) or `n` (reject) to
   open the `Harness_overrule` modal (pre-seeded only when the selected verdict
   carries a valid 64-char lowercase hex `notes_hash`; strict 64-hex validation
   enforced on submit).

#### Approvals

Pending operator decisions appear in two places:

- **Fast Approval Strip**: whenever an actionable item is waiting (held Tool
  Approval, Gate request, Ask, or Goal confirmation), a 1-row strip appears
  above the composer on every workspace.
  - For **Tool Approvals** and **Gate** items: press **`Y`** (unfocused) or **`Alt+Y`** (from composer) to approve, and **`N`** / **`Alt+N`** to deny (opening the reason modal for Gate rejection).
  - For **Asks**: the strip displays honest Ask actions (`[Y] Answer Ask · [N] Skip · [J] Inbox`). Pressing **`Y`** / **`Alt+Y`** opens the dedicated **Ask Answer Modal** (never blindly submitting choice #1, and preserving any composer draft). Pressing **`N`** / **`Alt+N`** skips **all** questions in that Ask honestly.
  - A Tool Approval answer toasts what the server did with it: the waiting
    call took it, the call had stopped waiting and the answer applies when
    the same call is retried, or no call was waiting. In the last case
    nothing is recorded, the item stays, and the held approvals are read
    again.
  - For **Goal confirmations**, `Y` never fabricates proof tokens — it dives
    into **Goal Dive** so you can review verified proof and submit the exact
    server-issued `criterion_revision`, `request_id`, `verification_run_id`,
    and `operator_id`.
- **Dedicated Ask Answer Modal** (opened via `Y`/`Alt+Y` on an Ask, `J` teleport on an Ask, or `Enter` on an Ask in `Pulse` / `2 Work → Inbox`):
  - Supports **single-select**, **multi-select** (`Space` toggles checkboxes), **multi-question** Asks (`[`/`]` or `Tab`/`Shift+Tab` switch questions with per-question progress chips `✓`/`⊘`/`○`), **UTF-8 free-text** (`i` enters text editing when `allow_free_text` is enabled; `Esc` exits editing while preserving the draft), and **skip** (`⊘`).
  - Press `↑`/`↓` (`j`/`k`) to move the cursor across all choices (scrollable, never capped at 4), `J`/`K` (or `Shift+↑`/`↓`) to scroll long prompts, quick-pick letters (`a..f`, `h`, `l..z`) to select/toggle choices, `Enter` to confirm/advance/submit, `Ctrl+Enter` / `Alt+Enter` to submit all questions at once, `C` to jump directly to the Keeper's Chat, and `Esc` to close while preserving the underlying view and composer draft.
  - **Live Status Guard**: if the Ask is already answered, withdrawn, or in-flight in live attention state, the modal displays a clear banner and disables duplicate submission.
- **Action Inbox (`2 Work → Inbox`)**: press `J` (`Alt+J` or `/jump`) from
  anywhere to teleport to the highest-priority blocked item (opening the Ask Answer Modal immediately for an Ask; pressing `Esc` leaves you focused on that Ask in Inbox). When a **single-question, single-select** Ask is focused, press **`a`–`d`** for instant submission (multi-question or multi-select Asks open the Ask Answer Modal pre-selected instead); press **`C`** to jump directly to the Keeper's Chat. In-flight submissions stay visibly tracked until acknowledged by the server.

### `3` Knowledge

Four 1st-class sub-tabs (`[` / `]`, and Left Navigation Sidebar `b`):

1. **Board**: workspace posts with Signal-only vs All filtering (`s`), Sort
   cycle (`S`: `recent` / `active` / `top`), live Hearth picker (`h` via
   `GET /api/v1/board/hearths`), and Succession Chain folding (`Space` strictly
   expands/collapses chains). Press `Enter` for **Thread Dive** (threaded
   comments with `<`/`>` comment cursor + depth rails, `c` comment/reply
   composer, two-press armed `+`/`-` voting on posts and comments), `n` to
   create a post, and `y` to copy post body.
2. **Wiki**: shared `.masc/wiki/` index, lint status, and Markdown preview
   (`Enter` opens Wiki Dive with outgoing links, backlinks, and revision log;
   `e` opens inline Markdown edit modal; `Ctrl+E` opens in `$EDITOR`; `y`
   copies Markdown body; `o` opens the first `http(s)` URL). A save toasts the
   revision it wrote, as a warning when the journal or index write failed, and
   the page is read again.
3. **Artifacts**: dedicated 1st-class tab for live published artifacts
   (`GET /api/v1/published-artifacts` + on-demand detail). Structured HTML DOM
   rendering (`Html_doc`: strips `<script>`/`<style>`/`hidden`/`aria-hidden`,
   renders headings, CJK-wrapped paragraphs, aligned tables, links, image
   badges), rich Markdown (`Markdown`), and pretty-printed JSON. Press `v` to
   toggle Rendered Document vs Raw Source, `{` / `}` to step revisions, `c` to
   toggle confirmation check (`/api/v1/published-artifact-checks`), `P` to
   toggle CAS external share (`/api/v1/published-artifact-shares`), `Y` to copy
   Public URL, `y` to copy raw body, `e` to export locally, `o` to export and
   open in browser, `H` to copy SHA-256, `z` to zoom, and `Enter` for
   **Artifact Dive** (`/` + `n`/`N` in-document search).
4. **Memory**: World Memory overview, Claims/Conflicts, Librarian writer status
   (`a` quick `resume`, `A` recovery act modal supporting `resume`, `adopt`,
   `restart_reading`, `skip_item`, `skip_line`), plus `[v]` sub-views:
   - **Diff & Flow**: **Memory Flow** Braille time-series chart (`g` toggles
     `Flow ▲/▼` vs `Net Total`, overriding the global `Home` / jump-to-top
     binding on Memory screens including `Memory_diff_dive` and `Keeper_memory`;
     use `Home` to jump to top) and **Temporal Diff Scrubber** (`w` cycles
     `24h` → `7d` → `30d`, `m` toggles World vs Keeper scope, `Enter` dives
     into `rev A..B` revision diff).
   - **Health & Ledger**: fleet Keeper memory health
     (`GET /api/v1/dashboard/keeper-memory-health`) and workspace memory ledger
     (`GET /api/v1/dashboard/workspace-memory-ledger`).
   - **Context**: workspace-wide ordinary & source-bound memory context summary
     (`GET /api/v1/dashboard/workspace-memory-context`).

### `4` Keepers

Three fleet modes (`[` / `]` when pane 0 is focused):

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
When focusing the right split pane (`Tab`) or diving into any Keeper (`Enter`,
or `c` straight into Chat), the top sub-tab bar syncs to all **9 Keeper tabs**
(`[` / `]` cycles tabs):

1. **Chat & Stream**: live streaming conversation (`POST /api/v1/keepers/chat/stream`),
   per-Keeper durable drafts, pending-delivery states (`Queued`, `Sending`,
   `Pending_processing`, `Confirming_delivery`), tool/thinking/origin toggles,
   and turn interrupt (`Ctrl+X` or `Esc` during an active turn).
2. **Context & Turns**: per-turn context window & execution-flow inspector backed
   by live `/turn-records`, `/turn-flow`, `/provider-input`, `/cache-outcome`,
   `/next-request`, `/turn-transcript`, `/tool-calls`, `/checkpoints`, and
   `/operator-note`, with SSE auto-refresh and live retry/checkpoint/native-tool
   progress tracking. Press `<`/`>` to step turns and `v` to cycle all **5 views**:
   **Composition** (context occupancy bar, carried history reach, stacked
   prompt/tool/message composition, and Next-Request Forecast band), **Turn Flow**
   (per-turn Intake · Failover attempts · parallel tool batches · block diff
   details · `memory_os` recall waterfall), **Exact Input** (wire-captured parts
   list, lazy `Enter` part viewer, graceful 401/403 permission notice, and Cache
   Outcome TTL + message-diff diagnosis), **Input Map** (SHA-256/bytes proof
   table), and **Response** (turn transcript joined by `execution_ids`). Also
   summarized in `Ctrl+T` → **Context** drawer (`Enter` dives straight into full
   view). Keeper lifecycle & context actions are available via `/ctl`.
3. **Tool Calls**: per-Keeper `/tool-stats` summary, `/tool-calls` table,
   unfolded `Json_tree` payload viewer, and lazy `Enter` `/tool-result` fetch.
4. **Memory**: `[v]` cycles 4 per-Keeper sub-views — **Diff & Flow** (scoped
   Temporal Diff `[w]`, **Memory Flow** Braille chart where `[M]` toggles
   between `Flow ▲/▼` and `Net Total`,
   **Retrieval Heat** stacked bar, Librarian recovery `[a]`/`[A]`), **Health**
   (`/api/v1/dashboard/keeper-memory-health?keeper=<name>`), **Facts Tree**
   (`/api/v1/keepers/:name/memory-facts` with `Enter` category expand/collapse),
   and **Journal** (`/api/v1/keepers/:name/memory-journal?limit=50&activity=1`).
5. **Work & Candle**: Keeper's linked Tasks, Goals, and Candle balance/equipped
   portrait items.
6. **Sandbox**: Keeper's sandbox backend, network mode, agent socket, shim
   parity, 24h tool metrics, and on-demand probe (`p`).
7. **Config**: in-place editor of Keeper TOML fields (`↑`/`↓`, `←`/`→`,
   `Enter`, `d` dry-run diff, `Ctrl+S` save, `Delete`/`Ctrl+D` remove, `/`
   filter, `e` full Settings). Works identically in both Keeper Dive and the
   `4 Keepers` split preview right pane.
8. **Logs**: remote-safe HTTP telemetry & sandbox stdout/stderr viewer (`v`
   toggles `/api/v1/keepers/:name/metrics` vs
   `/api/v1/gate/keeper-sandbox-logs`; zero local filesystem reads).
9. **Identity**: per-Keeper OAuth & GitHub identity manager (`l` OAuth login or
   GitHub SSE device flow login, `L` poll OAuth attempt status, `r` refresh
   identity, `a` / `Enter` switch OAuth enabled/disabled, `U` disconnect OAuth, `K`
   masked GitHub PAT modal — secrets are never echoed or logged, `y` copy OAuth
   authorize URL or GitHub device code; graceful `CanAdmin` notice on 401/403).

### `5` Runtime

Seven 1st-class sub-tabs (`[` / `]`, and Left Navigation Sidebar `b`):

1. **Quotas & Credits**: provider quota windows, 7-day usage history, and
   unreported accounts toggle (`u`, or `Enter` on the unreported toggle row;
   `r` forces a fresh `runtime-probe`).
2. **Efficiency & Spend**: 4-KPI summary strip, 24h **Prompt Cache Hit Rate
   (%)** Braille chart, 24h dual-axis throughput/spend chart, and group/keeper
   cost efficiency table (live updates via view-scoped `models/metrics/stream`
   SSE).
3. **Failover Lanes**: ordered lane cascades (`Enter` opens Lane Dive), runtime
   probe reachability (`Space` toggles outside-lane probes, `r` forces probe),
   operator lane CRUD (`n` create, `e` edit the single default runtime or reorder
   lane candidates, `R` rename a named lane, `d` or `x` open removal confirmation and
   enter the lane ID, plus `/lane` for exact-lane candidate `append`/`drop`/`move`/`replace`,
   raw config preview, verifier runs, and board-attention quarantine recovery),
   and deduplicated **`exact_lane_runs`** (`D` opens **Exact Run Dive** via
   `GET /api/v1/dashboard/exact-lane-runs/:run_id`).
4. **Fusion**: dedicated 1st-class tab for live **Fusion** multi-model runs
   backed by `/api/v1/dashboard/fusion-runs`, `/api/v1/dashboard/fusion-runs/:run_id`,
   `/api/v1/runtime/config/fusion` (presets for `[f]` Launch modal; graceful
   401/403 handling), and `/api/v1/board/:post_id` (`[e]` or `Enter` inside
   **Fusion Dive** loads linked board evidence). Right pane & **Fusion Dive**
   (`Enter`) display the full `Question → Panel → Judge → Evidence` pipeline,
   panel answers/failures/tokens, seat routing & fallback attempts, judge
   synthesis, tool-call trace preview, and replay warnings.
5. **Tools & Usage**: live tool telemetry, HITL quality, skills, prompts & presets
   (`v` cycles **5 sub-views**):
   - **Usage Calls**: `w` cycles `24h/1h`, `7d/1d`, `14d/1d` with totals strip,
     `Calls`/`Failed`/`p95` Braille curves, newest-first bucket table, and
     failure-class breakdown (live updates via view-scoped
     `tool-metrics/series/stream` SSE).
   - **Catalog Tree**: Domain → Family → Tool 6-column table joined from live
     `tool_inventory.tools` × `tool_usage.by_tool`; press `Enter` for **Tool
     Detail Dive** (description, schema, live per-tool series, and `[e]`
     stateless MCP `2026-07-28` Tool Executor).
   - **Keeper Surface & Skills**: `<`/`>` steps keepers to inspect live
     `effective_keeper_surface` budgets/origins alongside `/api/v1/skills`
     (`Enter` opens **Skill Dive** for SKILL.md read/edit/preview/delete/create/refresh;
     `n` creates a skill, `R` refreshes the skill catalog).
   - **Quality & Gate**: tool-quality success/latency/failure telemetry
     (`/api/v1/dashboard/tool-quality`), gate tool events
     (`/api/v1/gate/tool-events`), and per-keeper waiting inventory.
   - **Prompts & Presets**: 4-section manager (`Tab`/`[`/`]`) for system
     **Prompts** (`e` override, `x` reset), **Presets** (`n` create, `a`
     restore, `x` delete), **Runtime Params** (`e` set, `x` clear), and live
     **Async Requests** (`/api/v1/async-requests`).
6. **Connectors**: dedicated 2-pane screen for Channel Gate Connectors (`n`
   opens the Connector bind form: connector name such as `discord`, channel ID
   with live `/api/v1/gate/connector/names` picker via `←`/`→`, and the Keeper
   to bind via `?name=<connector>`, `U` unbind) on the left and Connected MCP
   Clients + Browser/Addons summary on the right (`Tab` switches panes).
7. **Addons & Browser (Operator)**: dedicated 2-pane operator cockpit (`Tab`
   switches panes; press **`p`** to toggle the **Package Catalog** browser backed
   by `/api/v1/lane-addons/package-catalog` & `/api/v1/lane-addons/package-preview`
   with `Enter` directory browse & package preview):
   - **Left pane — Addon Lanes**: `GET /api/v1/lane-addons` table (`Addon`,
     `Presence` `LIVE`/`RETAINED`, `Phase`, `Exec`, `Obs#/Rows`, `Decl`) with
     bottom detail & operator status strip (`instance_id`, `host_requests`,
     `visibility`, `action_schema`, latest action receipt, slice rows, and
     pending addon asks). Operator hotkeys: `n` attach, `e` declaration create/save,
     `c` execute addon action, `O` observe, `D` inspect slice, `x` open detach confirmation and enter the instance ID, `y`
     copy ID (full CLI via `/addon`).
   - **Right pane — Browser Clients & Open Tabs**: top table shows connected
     clients (`GET /api/v1/dashboard/browser-lane/clients`) plus
     `inventoryIssues` warning rails; bottom table shows per-tab listings
     (`POST /api/v1/dashboard/browser-lane/read`) fetched on client selection and
     on-demand with `t` (zero idle polling). Operator hotkeys: `Space` toggles
     Clients/Tabs focus, `c` interact modal, `O` capture scene, `W` capture
     screenshot, `y` copy tab URL, `o` open tab URL (full CLI via `/browser`).

### `6` Infra

Four 1st-class sub-tabs (`[` / `]`, and Left Navigation Sidebar `b`):

1. **Sandboxes**: fleet inventory of MicroVM guests (presence, agent socket,
   shim parity, volume), SSH pools (reachability, active/max sessions), and
   Docker keepers (`Enter` opens Sandbox Dive inspector; `p` probes selected
   keeper or all).
2. **Repos & Changes**: registered repositories (`n` opens add-repo modal, `o`
   opens repository URL, `y` copies repository URL) and the selected
   repository's file-writing tool calls from the last 24 hours, with the
   recorded text in the preview pane. Calls the server could not read are
   counted in the changes card's subtitle.
3. **Code**: workspace file browser, syntax viewer, and Git inspector backed by
   `/api/v1/workspace/{children,files,search,file}` and
   `/api/v1/git/{status,branches,worktrees,blame,log,diff}`:
   - **Left pane**: lazy collapsible directory tree (`Enter` expands folders or
     opens files; `s` cycles workspace scope across `project`, registered repos,
     and keepers).
   - **Right pane**: syntax-highlighted source viewer (`Code_lexer`, line
     numbers, `y` copies file path/content), `[p]` fuzzy file finder modal,
     `[f]` ripgrep code search modal (`Enter` jumps to file & line), and `[g]`
     cycles File vs Git Status / Branches / Worktrees / Blame / Log / Diff.
4. **Activity & Logs**: unified chronological **All / Server Logs / MASC
   Events** timeline merging initial `/api/v1/activity/events` backfill, live
   `logs/stream` SSE (`LOG`), and `observer/stream` activity events (`EVT`),
   with `SRC` badge column and scrollable right-hand **Structured K/V Detail**
   pane (`Tab` to scroll). Press `s` to cycle `ALL` → `LOGS` → `EVENTS`, `a` to
   toggle the **Acting Keepers** side-rail (`Enter` dives into
   **Runtime Trace Dive** via `/api/v1/keepers/:name/runtime-trace` or
   **Log Detail Dive**), `Space` to cycle log level filter (`All` / `ERR` /
   `WRN` / `INF`), `/` to filter text across both logs and events, and `y` to
   copy the selected log message or event detail (`Stream_gap` pill surfaces any
   dropped events honestly).

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
  change; `Delete` or `Ctrl+D` toggles key removal; **`d`** runs a
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
`Enter` to edit, `d` for dry-run diff, `Ctrl+S` to save via
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

### Viewing & Editing Addon Lanes, Browser Clients & Open Tabs

- **Configuration**: press `,` to open **Settings**, select category **`3`
  Routing & Failover** (or press `/` and search `addon_exact_lanes` /
  `exact_output_lanes`). The tree lists every `runtime.exact_output_lanes.<id>`
  (`Exact · <id>`) and `runtime.addon_exact_lanes.<id>` (`Addon · <id>`) table
  from `runtime.toml`. Edit fields with `Enter`, preview with `d`, and save
  with `Ctrl+S`.
- **Addon Lanes & Browser Lane Runtime (`5` Runtime → Addons & Browser)**:
  - **Left pane**: live `GET /api/v1/lane-addons` table (`LIVE`/`RETAINED`,
    `phase`, `execution_authority`, `observation_seq`/`rows_count`, declaration
    status) with a detail strip showing `instance_id`, `host_requests`,
    `visibility`, and declared `action_schema` actions. `lane_addon*` events on
    `observer/stream` automatically refresh the table when viewing `5 Runtime`.
  - **Right pane**: connected browser clients (`GET /api/v1/dashboard/browser-lane/clients`)
    with `inventoryIssues` warning rails on top, and per-tab listings
    (`POST /api/v1/dashboard/browser-lane/read`) for the selected client below.
    Press `Tab` to switch panes, `Space` to switch Clients/Tabs focus, `t` to
    refresh open tabs on demand, `y` to copy the selected addon ID or tab URL,
    and `o` to open the selected tab's `http(s)` URL.
- **Exact-Output Runs**: open **`5` Runtime → Failover Lanes** (`[ ]`) to view
  deduplicated recent **`exact_lane_runs`** alongside failover lane cascades.
  Fusion runs live on **`5` Runtime → Fusion**, and a 2-line Browser & Addons
  status summary also appears on **`5` Runtime → Connectors**.

### Viewing Memory Evolution

- **Workspace-wide**: open **`3` Knowledge → Memory**. The **Memory Flow**
  Braille chart plots real observed revisions from `memory_diff.revisions`
  (zero fabricated points): default `Flow ▲/▼` shows added facts/claims upward
  and removed/invalidated/retracted downward; press **`g`** to toggle to the
  backward-anchored `Net Total` curve. Press **`w`** to cycle the
  **Temporal Diff Scrubber** (`24h` → `7d` → `30d` → `rev`), **`k`** to toggle
  World vs Keeper scope, and **`Enter`** to open a `rev A..B` revision-range
  dive. Inspect Librarian writer states and press `a` (quick `resume`) or `A`
  (recovery modal for `adopt`, `restart_reading`, `skip_item`, `skip_line`)
  when a writer is stopped.
- **Per-Keeper**: open **`4` Keepers → select Keeper → `Enter` → Memory** tab
  (`[ ]`, or focus the right split pane with `Tab` and switch to **Memory**).
  Browse changes and facts in the explorer, and press `Enter` to read the
  selected record. Period Diff shows the **Memory Flow** chart (`M` switches
  between Flow and Net Total) and **Retrieval Heat**. Press `v` to reach
  **Health** for Memory OS diagnostics. It charts age and count when the pane
  has room.
- **Pele / Mermaid / Formation Tree Diagrams** (in **`3` Knowledge → Memory**
  with a Keeper selected, or **`4` Keepers → Keeper → Memory**, across all
  keeper-scoped subviews — `Diff/Flow`, `Facts Tree`, `Journal`, `Health`,
  `Context` — and compact widths `< 104` cols):
  - Press **`.`** on an evolution event or ordinary fact to open the **Pele
    3-stage SVG card** (renders live Kitty/iTerm2 pixels on Ghostty, WezTerm,
    Kitty, and iTerm2 — falling back to the active TUI theme palette when
    terminal `OSC 11` was not observed — and falls back deterministically to
    adaptive `Mermaid` text with automatic `LR`/`RL` → `TD` reflow otherwise).
    Ordinary facts outside the last 50 activity events open as an honest
    single-fact current-snapshot chart with no fabricated transition history.
    With no journal event or fact selected, **`.`** opens nothing and reports
    it instead of drawing an unselected memory.
  - Press **`Ctrl+O`** to open the **Formation Tree** (Pele Graph PNG or
    `Memory_tree` text fallback).
  - Inside an open diagram: press **`v`** to cycle `Auto (Pele)` → `Mermaid` →
    `Tree`, **`j`/`k`/`PgUp`/`PgDn`/`g`/`G`** to scroll text lines, **`y`** to
    copy diagram source, **`r`** to retry/refresh, and **`Esc`** to close back
    to the exact prior Memory subview.
- **Inline ` ```mermaid ` Markdown Rendering**: fenced `mermaid` code blocks in
  Board posts/comments, Wiki pages, Artifacts, Tasks/Goals, and Keeper Chat
  render directly as Unicode box-and-arrow diagrams (with automatic `LR`/`RL` →
  `TD` reflow on narrow viewports and safe code-block fallback for unsupported
  or oversized diagrams).

### Viewing Unified Logs & Live Events

Open **`6` Infra → Activity & Logs**. The left pane merges live server logs
(`GET /api/v1/dashboard/logs/stream`, tagged `LOG`) and MASC `observer/stream`
activity events (tagged `EVT`) into one chronological feed; the right pane
shows structured key/value details for whichever entry is selected (`Tab` to
scroll). Press `s` to cycle `ALL` → `LOGS` → `EVENTS`, `Space` to cycle log
severity filters (`All` / `ERR` / `WRN` / `INF`), `/` to filter text across
both sources, and `y` to copy the selected log message or event detail.

### Viewing, Copying & Exporting Artifacts

Open **`3` Knowledge → Artifacts** (1st-class tab, reachable via `[`/`]`,
`Ctrl+K` Palette, or the Left Navigation Sidebar `b`/`Ctrl+B`). Selecting an
artifact automatically fetches its full content
(`GET /api/v1/published-artifacts/<id>`) and renders a structured HTML
(`Html_doc`: headings, emphasis, code blocks, aligned tables,
`<script>`/`<style>` stripped), Markdown, or formatted JSON preview in the
right pane (`Tab` to scroll). Across the Artifacts list, **Artifact Dive**
(`Enter`), and **Media Viewer**:

- **`v`** — Toggle rendered view vs raw source.
- **`{` / `}`** — Step artifact revisions (older / newer).
- **`/`** — Search within **Artifact Dive** (`Enter` to dive, then `n` / `N` jump to next / previous match).
- **`c`** — Toggle verification check (`POST /api/v1/published-artifact-checks`).
- **`P`** — Toggle CAS share status (`POST /api/v1/published-artifact-shares`); **`Y`** copies the share URL via OSC 52.
- **`y`** — Copy the full raw HTML or Markdown body to your clipboard via OSC 52
  (fetching on demand if detail has not loaded yet; toasts byte count).
- **`e`** — Atomically export `.html`/`.md` to `$HOME/Downloads/masc-artifacts/`
  (or `<base-path>/.masc/exports/` when `$HOME/Downloads` does not exist) and
  toast the exact saved path.
- **`o`** — Export to the safe export directory and open the `.html`/`.md` file
  in your default browser.
- **`H`** — Copy the artifact's SHA-256 digest via OSC 52.

## Streaming vs On-Demand Architecture (Zero Idle Polling)

MASC TUI v2.6 enforces a strict connection budget in
`lib/masc_tui/store/subscriptions.ml` and `lib/masc_tui/store/update.ml`, and
reflects the **actual** data mode of the active view in the top bar and footer:

- **Honest Per-View SSOT Mode (`Model.active_view_ssot_mode`)**:
  - **`● LIVE SSE`** — active view is directly fed by a live SSE stream (`1 Pulse`, `4 Keepers` fleet/chat, `5 Runtime → Efficiency & Spend`, `5 Runtime → Tools & Usage`, `6 Infra → Activity & Logs`), showing stream count or `↻ RECON` / `⚠ STALE` honestly on degradation.
  - **`◐ SYNCED · <age>`** — snapshot view whose datasets are invalidated and refreshed by `observer/stream` events (e.g., `2 Work`, `3 Knowledge → Board / Wiki / Artifacts / Memory`, `5 Runtime → Quotas / Failover / Fusion / Connectors / Addons & Browser`, `6 Infra → Sandboxes`).
  - **`○ SNAPSHOT <age> · r`** — pure on-demand snapshot view with no active SSE or observer invalidation for that surface (e.g., `6 Infra → Repos & Changes`, `Artifact Dive`, `Wiki Dive`); press `r` to refresh. Mixed-mode views (`Tools & Usage`, `Connectors`, `Addons & Browser`) also show per-pane `LIVE SSE` / `SYNCED` / `SNAPSHOT` badges.

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
  - `5 Runtime → Tools & Usage`: `GET /api/v1/tool-metrics/series/stream`
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
  Push-to-Talk with `V` (unfocused), `Alt+V`, `F8`, or `/voice`;
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
own binary. Check its embedded build commit with `masc-tui --version`,
`masc-tui --build-commit`, or inside the `?` Help and `,` Settings overlays
(which show both TUI and connected Server build commits and flag mismatches).
Rebuilding or restarting `bin/main_eio.exe` does not replace an
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

### Board quarantine recovery

Open a Keeper’s **Work & Candle** tab and press `v` to read its Board quarantine inventory. Select a candidate with the arrow keys. The detail shows its full candidate, partition and quarantine IDs. Press `c` to acknowledge and requeue that generation. The TUI reads the same Keeper’s ledger again and displays the recorded phase beside the command result. Press `r` to read the ledger again.
