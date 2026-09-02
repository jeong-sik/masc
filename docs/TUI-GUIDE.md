---
status: runbook
---

# MASC TUI Guide

Terminal UI over a MASC runtime root. It reads `.masc/` directly and, when a
server is reachable, adds the surfaces that only exist over HTTP. Surfaces
rotate with `Tab` in the order `surface_ring` spells in
`bin/masc_tui_types.ml`: Overview, Activity, Keepers, Memory, Approvals,
Board, Planning, Workspace, Runtime, Config.
Eleven more surfaces hang off parents instead of holding Tab stops:
Planning's `v` walks Task Review, Evaluator Verdicts, Schedules, and Fusion;
the Keepers roster reaches Changes with `f`, and Keeper detail owns Channels,
Automation, and Runs as tabs. Runtime reaches standalone Lanes with `p` (its
third stop), Workspace reaches Code with `Enter` on a repository row, and
Config reaches Resources with `s` and Tools with `t`, and Activity
reaches the server log with `l`. Task Review, Schedules, Fusion, Lanes,
Code, Resources, Tools, and Logs also keep `go <name>` palette entries;
Verdicts, Changes, and Keeper operations are reached from their parents
only.

## Quick Start

```bash
dune build --root . bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/me
```

`.masc` must live directly below the path you pass. The base path resolves as
`--base-path` -> `MASC_BASE_PATH` -> current directory, so the shorter form is
`MASC_BASE_PATH=~/me ./_build/default/bin/masc_tui.exe`. An installed build is
`masc-tui`.

Point it at the same root the server uses. A TUI reading one root while the
server writes another shows stale keepers with no error, because both roots are
valid on their own.

## Options

| Option | Default | Effect |
|--------|---------|--------|
| `--base-path` (`--base`) | `MASC_BASE_PATH`, then cwd | Directory holding `.masc` |
| `--port` | `8935` | MASC server port on `127.0.0.1` |
| `--refresh` | `2` | Seconds between refreshes |
| `--workspace` | derived from base path | Workspace label in the header |

## What the server changes

The TUI runs without a server. Which surfaces stay useful is not a detail - it
decides whether launching one is worth it.

| Surface | Without a server | Source |
|---------|------------------|--------|
| Keepers (list, detail, logs) | fully works | `.masc/keepers/`, turn records, metrics store |
| Overview - Tasks panel | works | `.masc/tasks/backlog.json` |
| Overview - summary, Attention | unavailable | `GET /api/v1/dashboard/briefing` |
| Overview - transport tail | unavailable | `GET /api/v1/dashboard/transport-health` |
| Lanes | unavailable | `GET /api/v1/keepers/composite` |
| Approvals | unavailable | `GET /api/v1/operator`, `POST /api/v1/operator/confirm` |
| Board | unavailable | `GET /api/v1/board` |
| Planning | unavailable | `GET /api/v1/dashboard/planning` |
| Keeper Automation | unavailable | `GET /api/v1/dashboard/scheduled-automation`, filtered to the selected Keeper |
| Keeper Runs | unavailable | `GET /api/v1/dashboard/fusion-runs`, filtered to the selected Keeper |
| Runtime | unavailable | `GET /api/v1/runtime/resolved` + `GET /api/v1/dashboard/runtime-probe` |
| Keeper message | unavailable | `POST /api/v1/keepers/chat/stream` |
| System Logs | unavailable | `GET /api/v1/dashboard/logs` |

An unreachable server is reported, not hidden. The header shows
`[disconnected]`, the surface prints the failing call, and each failed load
lands in Recent Events:

```
 MASC Board (0)  10:55:37  [disconnected]
   (data unreliable: board load failed: (GET failed: Connection Error: ...
```

A count of `0` next to `data unreliable` means the read failed. It does not
mean the board is empty.

## Navigation

Every surface draws the Tab ring on its top row with the active surface
highlighted; narrow terminals window the strip around the active entry and
show how many entries hide past each edge (`‹4`, `5›`).

| Key | Effect |
|-----|--------|
| `Tab` / `Shift-Tab` | next / previous surface in the strip's order |
| `?` | help screen -- every binding, grouped by surface; `j`/`k` scroll, `Esc` closes |
| `:` | command palette -- type to filter `go <surface>` and `keeper <name>` jumps, `Enter` runs the highlighted one |

On the keeper roster, `/` searches names: typing moves the cursor to the
first match live, `Enter` keeps the query for `n`/`N` cycling, `Esc` keeps
nothing. The list itself never narrows, so every action still acts on the
row it shows.

`NO_COLOR` (non-empty) suppresses colour; borders, markers, and the
reverse-video selection stay. `MASC_TUI_FORCE_COLOR=1` overrides.

The Config surface's Themes pane picks a bundled base16 scheme (monokai,
solarized, and others) for the session. To keep a pick across restarts,
name it in `runtime.toml` under a `[tui]` table — the TUI reads it at boot
and applies it, and an absent or unknown name just follows the terminal:

```toml
[tui]
theme = "monokai"
```

The table measures the seven colours MASC uses for semantic text against a
4.5:1 contrast floor. `native 7/7` means the theme clears it without help;
`lift N/7` means MASC raises those colours to the floor. With
`[tui].lift_colours = false`, the same risk is shown as `N/7 low` instead of
pretending the colours were lifted. Native-pass schemes are listed first;
assisted schemes follow by lift count, and equal counts are alphabetical. The
header reports both the bundled total and the native-pass count, so the
high-contrast candidates no longer have to be found by scanning an unordered
catalog. Theme names are fitted by terminal cells, so long bundled names keep
the swatch, page, and contrast columns aligned.

Keeper sub-views spell their position as a breadcrumb in the header:
`Keepers ▸ <name> ▸ chat` (also `logs`, `calls`, `runtime`).

The keeper detail pane has tabs, cycled with `[` and `]`: Info, the
keeper's declared instructions with its effective system prompt, and its
GitHub CLI identity observation. On the GitHub tab, `L` starts the gh
device-flow login and streams its (redacted) output into the pane; when
the stream ends the pane re-reads the identity observation.

Reading a board post on a wide terminal keeps the post list beside it.
`Ctrl-W` toggles focus; `h` selects the list and `l` selects the post. `j`/`k`
then move the focused pane, while `PgUp`/`PgDn` move it by a page. The open post
remains marked when the detail has focus.

The Config surface shows `runtime.toml` as the server reads it; `e` opens
it in `$EDITOR` and the server's preview validation gates the write. The
Resources surface hangs off Config under `s` and lists every MCP
resource; `Enter` reads one beside the
list. The detail starts with the server's description, full URI, MIME type,
and declared byte size, then the payload. JSON is pretty-printed; JSON, TOML,
and YAML payloads use the shared code lexer, while Markdown uses the same
renderer as chat and Board; binary parts report their encoded size instead of
pretending to render content. With detail focused, `[`/`]` read the previous
or next resource without returning to the list. Responses are URI-stamped, so
a slow older read cannot replace a newer selection. `Ctrl-W` switches between
list and detail, and `j`/`k` move whichever pane has focus. The selected
Keeper's Channels tab shows transport status; `b`/`u` open a binding form with
that Keeper already named.

Tools has five deliberately different questions under `p`: `available` is
the effective surface delivered to the selected Keeper now; `async runs` is
the composition broker's live queue/recovery state; `receipts` is the current
Keeper session's retained Skill activation ledger; `usage` is the workspace
roll-up of actual Skill invocation/delivery/action counts; and `all tools` is
the registered catalog. Registration or availability does not prove actual
use, and a missing retained receipt does not prove a Skill was never used.

At 110 columns and wider, the keeper detail view keeps a roster pane on its
left with the cursor marked; keys keep their detail meaning. Narrower
terminals use the single-pane layout. `Ctrl-B` changes the roster preference
only while the pane has room to show. Below 110 columns it reports the width
requirement and leaves the preference unchanged, so resizing wider cannot
reveal a hidden toggle that had no visible effect when it was pressed.

## Surfaces

### Overview

Workspace health, agent count, pending approvals, incident count, the Attention
list, Recent Events, and active tasks.

```
 MASC Overview  [me]  10:54:52  [connected]
   Health: bad  Keepers: 10  MCP agents: 2  Approvals: 0  Incidents: 4
   Cluster: default          Project: me      websocket/steady  sse 3  ws 1  grpc :8936
 Attention                              | Recent Events 1-5/5
 [bad ] analyst needs operator atten~   | [10:54:52] TUI started
 [warn] sangsu has external attention   |
 Tasks
   * [task-317] Apply File_lock_eio to approval queue (in_progress @keeper-...)
   o [task-272] Add HTTP route regression coverage (todo) !
  j/k:events  q:quit  r:refresh  Tab:next  2:keepers  | Refresh: 2s | Port: 8935
```

`j`/`k` scroll the events pane, not the task list. `t` hands `j`/`k` to the
task list instead; under task focus, `Enter` opens the selected task in full -
description, status with its assignee and timestamps, handoff summary, the
completion contract's evidence list, attached files - read from the same
backlog load the list was projected from. `Esc` closes the detail, a second
`Esc` returns `j`/`k` to the events. Events are windowed against
both panel columns, so a long event wraps to the width actually available
rather than the header width.

The tail of the cluster row is what the server reports about its own delivery
paths: the primary path, queue pressure, and per-path session counts. It rides
that row rather than taking one of its own, so a short viewport does not trade
an event line for it. A path that is not listening reads `off` rather than as
zero sessions, because those are different facts, and a nonzero drop count is
spelled out - a steady queue that drops is not a healthy transport.

This tail is read only while Overview is the current surface.

The same row ends with the runtime event feed: `feed: live 1240` while the
TUI is subscribed to `GET /mcp?sse_kind=observer` and counting the frames it
has received, `feed: opening` while the MCP session and the subscription are
being set up, and `feed: closed after N` once the stream has ended (the
reason is in Recent Events and on the Activity status row) -
the count stays so a stream that dropped after a thousand events and one that
never opened do not read alike. The feed is opened after the first refresh
that reaches the server and reopened on the refresh cadence after it closes;
both transitions land in Recent Events. Every keeper's tool calls, turn
boundaries, heartbeats, and turn settlements arrive on it; this build keeps
the last 1,000 and counts what falls off the end.

Tasks show terminal states in Planning rollups but not in this list. A task
detail that is open when its task turns terminal stays open - the detail reads
the full backlog rows, not the active projection.

### Activity

Every keeper's actions as the runtime event feed delivers them, newest first:
tool calls and their returns, turn boundaries and settlements, chat rows
landing. This is the surface for watching ten keepers at once without
opening ten chats.

```
 MASC Activity (212 of 640 held, actions)  01:12:04  [connected]
   feed: live 640  dropped 0
   Time     Keeper             Event            Detail
   01:12:03 analyst          ▶ call             read_file [1/2] · turn 2086 · task-494
   01:12:03 analyst          ✓ returned         read_file · 32ms [1/2] · task-494
   01:11:58 rondo            ■ turn settled     turn 2086 · in 73877 out 358 · $0.0258 · 0 calls
   01:11:51 taskmaster       ● turn start       turn 1738
  j/k:scroll  g:newest  G:oldest  f:filter  Tab:next  q:quit  | Port: 8935
```

The glyphs are the same vocabulary the Keepers roster uses: `▶` a call
started, `✓` a call returned, `✗` a failure, `●` a turn boundary, `■` a turn
settled, `?` something needing attention, `·` the quiet kinds. A returned
call shows how long it took when its start is among the events held; a
call that began before the feed opened shows none.

`f` cycles three explicit scopes. `turns` is the default and folds each Keeper
turn to one row while leaving internal agent runs and approvals separate.
`actions` shows the flat calls, returns, turn boundaries, settlements, and chat
events. `everything` additionally shows heartbeats, composite/snapshot pushes,
chat stream frames, waiting-queue changes, and telemetry. Its quiet gray `·`
rows are state observations, not failures; `composite` specifically means the
Keeper composite snapshot changed. `agent start`/`agent done` are internal
agent runs rather than Keeper turn boundaries. The current scope and these
meanings are printed above the table, not hidden in this guide. An event kind
this build was not taught always draws by its wire name, so a new kind is
noticed rather than filtered away.

Scrolling down into older rows (`j`) freezes the view: new events count up
in `N new above (g)` on the status row instead of pushing the rows you are
reading. `g` returns to the newest row and clears the count; `G` goes to the
oldest held. The TUI holds the last 1,000 events; `dropped N` says how many
fell off the end while it ran.

### The composer and /task

The input row at the bottom of every surface sends text to the keeper it
names. A line that starts with `/` is a command for the TUI instead:

- `/task <title>` — followed by any further lines as the body — creates a
  task over the server's `masc_add_task` tool and then messages the keeper
  the operator's own words with the new id in front: `[task-512] <title>`.
  The keeper claims that exact task. The events row records the creation;
  a failure puts the typed text back into the input, unsent.
- Any other `/word` is reported as unknown and sent nowhere - a mistyped
  command must not become an instruction the keeper acts on. Text that
  merely contains a slash later in the line is a message.

### Keepers

Every keeper under `.masc/keepers/`, sorted by name.

```
 MASC Keepers (10)  10:55:25
    HEALTH       KEEPER             A P S   LAST LIFECYCLE / RUNTIME             TASK
 >  ● healthy    adm-race-cf-001    A P D  4m12s running anthropic.claude-opus-5 task-471
    ● idle       analyst            A - M  2h08m paused kimi.kimi-k2.5           task-464
   OPERATIONS  lifecycle running · turn executing · idle 7m · last done · deepseek-v4 · running_fiber_alive
  j/k move  p pause  w wake  s shutdown  g yolo  c chat  right/enter detail
```

`A` is autoboot, `P` is autonomous turns, and `S` is the sandbox profile as a
letter — `D` docker, `M` microvm, `L` local — because a sandbox is a name, not
an on/off. `LAST` is the time since the keeper's last turn (the lifetime turn
count moved to the detail pane; a keeper that never turned shows a dash). The
metadata list needs no server, so names, last-turn times, and tasks stay
readable while the runtime is down. `HEALTH`, `LIFECYCLE / RUNTIME`, and lifecycle
actions come from `GET /api/v1/gate/keepers`; an unread live roster is shown as
`- unread` rather than guessed from metadata. The status glyph is the primary
colour cue. `healthy` answers whether the heartbeat/readiness checks are good;
`running` answers whether the Keeper process exists. They are separate axes,
so `healthy` and `running` on the same row is expected. The runtime cell joins
that phase to the producer's full canonical `runtime_id`; the TUI does not split
the opaque id to guess a model. If the fixed-width column cannot hold a long id,
it keeps both the shared head and distinguishing tail around a middle ellipsis.
Phase and runtime identity stay neutral so an ordinary row does not turn into a
strip of competing colours.

The fixed `OPERATIONS` line follows the selected Keeper. It comes from
`GET /api/v1/keepers/composite` and keeps the current lifecycle, turn step,
idle age, last runtime/model outcome, and producer diagnosis together on the
surface that owns Keeper operations. A failed refresh preserves the previous
typed reading and marks it unavailable rather than replacing it with guessed
zeros.

`g` toggles the selected Keeper's tool gate. The footer names the action that
will happen next: `g yolo` from the approval policy and `g auto` while YOLO is
active, so the safe return path is visible.

What YOLO covers is narrower than the name. It skips the approval hook that
asks over the open chat stream, and nothing else. External effects that go to
the Gate — writing to a service the Keeper is attached to, a sandbox command,
a durable memory write — are still decided by the workspace Gate mode and that
Keeper's own override, whatever this toggle says. It is in memory too: a
restart puts every Keeper back on `auto`.

### Lanes

Standalone execution lanes only. Keeper lifecycle and turn-cycle facts live on
Keepers, so this surface no longer repeats a second Keeper table. It hangs
off Runtime rather than holding a Tab stop: `p` on Runtime walks keeper
lanes, all runtimes, and then this surface. From the lane overview, `p` or
`Esc` returns to Runtime; inside the run list and run detail, `Esc` first
backs out one drill-down level as before. The palette keeps `go Lanes`.

```
 MASC Lanes · Standalone (4 lanes)  17:02:53  [connected]
  Standalone LLM lanes · READ-ONLY OBSERVATION · observed 17:02:52
 >● Librarian       running 12s    slots librarian-exact  active 1  runs 50  ok/fail/cancel 47/2/1
```

Rows come from `GET /api/v1/dashboard/standalone-lanes`. They show admission slots,
current activity, retained run counts, execution outcomes, latency, and the
slots actually selected. This build projects four fixed consumers:
`Board Attention` judges one durable Board attention candidate, `HITL Auto
Judge` judges one held approval, `Librarian` selects the next Memory OS
snapshot from immutable Keeper history, and `Verifier` reviews Task completion
and Goal proof evidence.

The selected row expands underneath the matrix instead of forcing its long
identifiers through the clipped comparison row. It names the exact
`[runtime.exact_output_lanes.<lane-id>]` table, every admitted catalog slot in
attempt order, the official-client runtime suffix used only after catalog
exhaustion, publication-dropped slots that will not execute, and any admission
error. In `runtime.toml`, `slots` is a required non-empty array of opaque
catalog references; `cli_slots` is an optional array of official-client runtime
ids. Blank values and duplicates are rejected. The lane tries admitted catalog
slots in declaration order, then CLI runtimes in declaration order. The
configuration is TOML; an individual run's Input and Output are retained JSON
evidence, not another lane configuration format.

Board Attention, HITL Auto Judge, and Librarian are schema-constrained
structured-output generation flows, not MASC tool loops. Their run evidence is
the exact Input and Output, outcome, elapsed time, and selected slot; there is
no omitted tool-call ledger for those runs. Their outputs mean, respectively,
the accepted Board candidate judgment, the validated and durably settled HITL
context judgment summary, and selected memory facts plus committed snapshot
metadata. Verifier is different: its Task/Goal review records also retain the
verdict reason, evaluator runtime, and MASC tool observations, which appear in
the exact run detail.

`j` / `k` moves the lane cursor. `e` opens that lane's exact table in the
Config `runtime.toml` source pane; another `e` uses the existing editor,
server-side preview, and save path. Right or `Enter`
opens that lane's recent exact runs, and another Right or `Enter` opens the
exact run record. Input and output are pretty-printed as syntax-highlighted
JSON and long JSON lines wrap by terminal cells, so a value does not disappear
behind the right edge. Each payload is bounded at 64 KiB; a larger retained
value says its original byte count instead of ending in an unexplained `~`.
A standalone lane has no Keeper identity, so `c` / `m` explains that chat
belongs on Keepers instead of silently opening an unrelated Keeper.

`Verifier` joins two durable review registries: task completion-authority
reviews and Goal proof reviews. Its run list names `task <id>` or `goal <id>`
in the subject column and keeps the producer verdict (`approved`, `rejected`,
`committed`, `deferred`, or the exact failure) as the status, so approval and
rejection do not require opening every row. Detail names the review kind and
shows the request followed by the retained result, reason, evaluator runtime,
and tool observations including input, disposition, output excerpt, duration,
and truncation state. The server filters a lane before cursor pagination;
Verifier history is therefore not hidden behind a busier Librarian window.

### Keeper detail

Right or `Enter` from the Keeper list or Lanes. Live context comes from the
newest trace-matched TurnRecord; missing, malformed, unreadable, usage-less,
and prior-trace observations stay distinct unavailable states rather than
collapsing to zero.

```
 Keeper: code-reviewer
   Identity
   Name:                  code-reviewer
   Generation:            1
   Paused:                no
   Current Work
   Task:                  -
   Last Blocker:          -
   Live Context
   Context:               8.9%  ##--------------------  93213 / 1048576 tokens
   Observed:              2026-08-23T01:53:26
   Turn Ref:              trace-1787333553810-0001a#429
   Runtime Stats
   Total Turns:           429
   Total Tokens:          37669331
   Total Cost:            $3.7016
   Last Turn:             2026-08-23T01:53:26
  j/k:scroll  l:logs  m:message  Esc:back  Tab:next  q:quit  r:refresh
```

### Keeper logs

`l` from detail. The newest 200 physical rows from the keeper's dated metrics
store, spanning month boundaries and rotated day segments. Reads are bounded by
row count, not file size.

```
 Keeper Logs: sangsu  (85 entries)
   Time     Kind Channel   Msgs          In/Out       Lat      Cost  Work
   14:31:08 turn turn         7            10/12       0ms    $0.000  tool_use
   14:31:32 hb   hb          --            --/--        --        --
  j/k:scroll  Esc:back  q:quit  r:refresh
```

| Field | Meaning |
|-------|---------|
| Time | `HH:MM:SS` from the row timestamp |
| Kind | current `keeper.metrics.v1` Turn or Heartbeat row |
| Channel | canonical short label (`turn`, `sched`, `hb`) |
| Msgs | observed message count, `--` when the heartbeat did not observe it |
| In/Out | `input_tokens` / `output_tokens` from usage |
| Lat | observed `latency_ms`, including zero; `--` when unavailable |
| Cost | observed `cost_usd`, including zero; `--` when unavailable |
| Work | `work_kind` label |

Malformed JSON, current-schema decode failures, and storage failures are shown
rather than skipped. Rejected rows consume the 200-row window and are never
backfilled with older data. A current-schema row whose `name` does not match the
selected keeper is rejected instead of being attributed to it by file location.

### Keeper calls

`t` from the roster or from detail. The keeper's durable tool-call log, the
newest page of `GET /api/v1/keepers/<name>/tool-calls`: one row per call
with the finished glyph or `✗` for one that returned an error, the tool,
its duration, the turn it ran in, and the subject the call is known by -
the same naming the chat rows use. The header carries the server's own
freshness verdict (`ok · latest 12s ago`), so a stale page does not read
as a quiet keeper, and a row naming another keeper is counted and not
drawn rather than attributed by file position.

```
 Keeper Calls: rondo (100)  ok · latest 8s ago  02:51:40  [connected]
   Time     Tool                     Dur      Turn   Subject
   11:36:57 ✓ Read                   28ms     2143   keeper_owner_reducer.ml
   11:36:38 ✗ tool_execute           14.5s    2142   dune build
  j/k:scroll  Esc:back  Tab:next  q:quit  r:refresh  | Port: 8935
```

### Keeper message

`c` (or `m`) from the roster or detail. Sends to the keeper over
`POST /api/v1/keepers/chat/stream` with a durable UUIDv7 request ID. The send
runs in the background, so refresh and navigation stay responsive while the
turn runs. `Esc` returns to the roster when chat opened there, and to detail
when chat opened from detail.

```
 Message to: sangsu  ● active · running anthropic.claude-opus-5  (port 8935)
   [14:35:01] From [you             ] tui-019...
     hello, how are you?
   [14:35:03] From [sangsu          ] tui-019...
     ...reply text...
   > type here_
  Enter:send  Ctrl-G:next Keeper  Esc:list  Ctrl-U:clear
```

The header joins the selected Keeper's published status with its typed runtime
phase and producer-owned canonical `runtime_id`, using the same roster reading
as the Keepers table. It also always names the chat approval stance
(`AUTO` or `YOLO`) and the effective durable Gate mode (`gate:auto_judge`,
`gate:manual`, or `gate:always_allow`). A Keeper that inherits `workspace`
shows the observed workspace mode rather than the word `workspace`; an unread
Gate observation stays `gate:?`. It never derives a model by parsing the id.
When there is room, the Context item includes percentage, current/maximum token
counts, and `^X`; narrower panes progressively keep the percentage before
dropping the whole item. In a narrow split pane, only the displayed runtime id
is middle-fitted so operational modes remain truthful in the header. While no
turn is starting or running, `Ctrl-G` selects the next readable Keeper and
wraps at the end of the roster. Each Keeper keeps its own draft. Every history
GET carries a load generation, so a response that finishes after the operator
switched away or left and returned is discarded instead of replacing the
newer transcript. The shortcut is withdrawn while a turn is in flight or the
roster cannot be read.

`From` is a fixed-width reverse-video badge for conversation sources: operator
sources are cyan, Keepers blue, status yellow, and errors red. Tool and
reasoning stretches are subordinate activity, so they use a quiet gray section
label instead of competing with the people speaking. Ordinary operator and
Keeper prose uses the terminal's default foreground so Markdown, code, links,
and emphasis keep their own hierarchy. Connector and agent origins remain in
the badge label (`vincent · slack`, `taskmaster · agent`) instead of being
inferred from row position.

Chat opens in the clock-free compact layout: the speaker mark and label remain
beside the prose while bookkeeping stays out of the reading path. `Ctrl-F`
adds an inline clock, then a full timestamp/request-id heading; the header names
those added projections as `metadata:inline` or `metadata:full`. A streaming
row uses its actual start clock rather than the word `live`; the active-turn
status below the history carries the live state and elapsed time. When
one newest message is taller than the history pane, the live edge keeps its
heading (or inline opening) and latest rows with an explicit
`⋯ N hidden · PgUp` separator.
That separator is a viewport projection, not a transcript row, and remains
readable under `NO_COLOR`.

The pane opens on the keeper's durable transcript. A turn the keeper ran on
its own is drawn as what it did, not as a blank line. Reasoning starts hidden
and tool calls start as one compact activity row, so the answer remains the
strongest level in the pane. `Ctrl-R` cycles reasoning through hidden, folded,
and full; `Ctrl-D` toggles compact and full tool details. `/thinking` and
`/tools` expose the same choices by name. `--reasoning` and `--tool-view` can
override the initial modes.

Memory journal rows open in summary mode, using producer-owned compact text
instead of reconstructing a summary from rendered prose. The summary itself
ends in `Ctrl-N: journal detail`; `Ctrl-N` or `/memory`
cycles those rows through summary, full, and hidden; the header names the two
non-default states as `memory:full` and `memory:off`. Neutral system rows that
share the journal lane have no summary projection and therefore remain whole.

The folded tool row retains exact outcome counts and ends with
`Ctrl-D: details / diffs`, so the hidden change view is discoverable from the
row that owns it. The typed calls themselves stay attached to the message, so
changing the view does not reconstruct facts from rendered glyphs. Expanded
Tool folds also retain operational kinds (`Skill`, `Keeper`, and `Fusion`), so
a mixed block does not collapse into an anonymous tool count. A held tool call
uses decision vocabulary independently of execution: `approval approved`,
`approval denied`, `approval timed out`, or `approval displaced`. Its later
tool row still reports whether execution returned or failed.
calls use the finished glyph for a call that
returned, `✗` for one that returned an error, `·` for one the trace never saw
finish, and `?` for one whose outcome the trace did not record. A finished call
carries its server-recorded duration; an open call has none.

Full tool detail also keeps a Keeper's recorded file change inside the turn
that made it. The pane does not fetch file-change bodies in compact mode;
`Ctrl-D` opens Full and performs that lazy read. A tool row joins a change only
by the producer's canonical `execution_id` — provider call ids, paths,
timestamps, and list position never authorize the join. The inline block names
the resolved file address, added/removed row counts, producer-recorded old/new
line ranges, and a bounded `diff` preview. At most three changes are expanded
per tool block and each preview holds at most twelve rows; an omission names
its exact count and points to Changes for the complete view. A historical row
without line evidence keeps its diff but invents no coordinates. A Write names
its recorded new body and range only, because previous content is unavailable.

When an autonomous turn says something, its badge is `· auto` instead of the
Keeper name used for a direct chat reply. A blank autonomous turn with no trace
still draws one `·` row, so the turn is visible without pretending it answered
the preceding operator message.

```
 [21:41:34]  tools
   ✗ Ran 2 tools · 1 returned, 1 failed · 2 details folded
```

Only rows the server marks as autonomous turns are read this way. A turn
in the conversation itself already has its calls in the transcript as tool
rows, so its trace block is not drawn a second time.

Conversation turns remain structural: rows inside one request use typed
Input → Progress → Tool → Output phase and producer operation sequence. Each
request phase, broadcast, and Memory journal observation then shares the
displayed clock as one chronological axis. A parallel Journal row can sit
between a request and its later reply; the reply is marked `↳` with the same
request label instead of being mistaken for a new turn. If a producer clock
would reverse phase order, the later phase is clamped to the latest preceding
phase on this display axis. A phase with no valid source clock inherits that
frontier; a leading unknown phase borrows the request's first later valid
clock so it cannot fall behind its own output. Only an entirely clockless
request reads `--:--:--`, never a fabricated epoch time. Stable server row IDs
keep scroll anchors through refresh. A turn that is still streaming follows
its latest committed causal frontier instead of escaping to a separate
bottom-only lane.

Only a request-correlated terminal keeper result is rendered as a reply.
Interrupted streams, protocol errors, rejected turns, and terminal outcomes
without visible text become explicit status or error rows; partial text is never
promoted to a successful reply. Requests are tracked per keeper, so a turn
running for one keeper does not decide what `Enter` does in another's window;
sends going elsewhere show as `(also sending to X)`. Drafts are retained per
keeper while navigating.

#### Context inspector

`/context` opens three readings for the selected Keeper: `1:stack` summarizes
the recorded context composition, `2:request` lists the exact canonical input
items retained for the provider request, and `3:proof` explains each recorded
component's source and evidence strength. At 110 columns and wider, the request
and proof tabs draw two columns with their headers pinned above independent
windows: `j`/`k` moves the left list while the selected item's text or
provenance stays put at the top of the right column, `h`/`l` moves which pane
hears `j`/`k` (the caret on the pinned header names it), and with the right
pane focused `j`/`k` scrolls the item itself. Narrow terminals keep the same
facts in one column; `Enter` opens exact text at full width.

`1:stack` is three measurements of one turn, not three views of one number,
and the section says so at the bottom. SERIALIZED REQUEST is the request the
dispatcher actually serialized, in bytes and in the provider's own token
count. HISTORY REACH is how much of the Keeper's recent history that request
carried: atoms are the indivisible units a cut falls between, so a tool call
and the result it answers travel together or not at all, and the count says
how many stayed behind — which is where "why does it not remember that"
usually ends. COMPOSITION divides the turn's attributed bytes by where they
came from (tool results, memory recall, schemas) and is a proportion table,
not a breakdown of the request: the attributed total and the serialized bytes
are measured at different points and the gap is not explained. A provider
that reports usage across the whole conversation rather than per request
gets no window percentage here, only the number it reported and a note that
this request's own share was not. RECENT TURNS, the section at the bottom,
is one row per dispatched turn on the fetched page, carrying the input,
cache read, and output the provider itself counted — the per-turn answer to
how much context goes in, newest first.

`2:request` marks where each item stands in the assembly: `F` the fixed
system prompt, `H` history the window carried forward, `N` the newest
message added this turn (the wire is append-only, so the last message is the
turn's own input, whether a user's text or this turn's latest tool result),
`S` a tool schema. The header also states what came back, to the extent the
turn record observed it: output tokens and the finish reason. An item's text
is the retained pre-dispatch copy; message rows are read as their typed
blocks — prose as markdown, structured payloads as pretty JSON, tool calls
and results under labels that name the tool and the outcome.

Evidence badges are claims, not decoration. `VERIFIED` means exact text was
checked against the producer digest and byte count. `SERIALIZED` means an exact
same-turn pre-dispatch request snapshot exists but no item-level key joins that
component to one retained item; it does not claim transport began or the
provider accepted anything. `DIGEST ONLY` means a producer prompt-block digest
is retained without same-turn exact text. `BYTES ONLY` means only the component
byte count is available. The inspector never joins independent readings by
label, position, or similar-looking content.

#### Pasting

The surface turns bracketed paste on (`ESC[?2004h`) while it runs. Without it a
terminal delivers a paste as the keys it looks like, and the line break in
pasted text is the same byte Return sends: a three-line paste becomes three
messages, and during a turn, three queued fragments. With it the payload
arrives as text and lands in the draft whole, so Markdown blocks, URLs, and
log excerpts keep the shape they were copied in.

A paste while the composer row is idle takes focus for it, so pasted text
always lands somewhere visible and addressed to the keeper the row named. With
no keeper to send to, the paste is refused out loud in Recent Events rather
than dropped.

A paste longer than 50 lines, or larger than 8 KiB, is not put into the draft.
The composer is five rows; a four-hundred-line paste in it is a draft nobody
can read, and a draft nobody can read is a message nobody can check before
sending. One line stands in its place:

```
   > [pasted 400 line(s), 3489 bytes → pasted-20260825-0211-01a034c1.txt]
```

When the message is sent, the text is written into the Keeper's own directory
and the placeholder becomes a line naming that file. A Keeper reads paths
relative to its sandbox root and refuses anything outside it - `/tmp` comes
back as `path_outside_sandbox` - so the file goes into the root
`Keeper_sandbox_config` reports for that Keeper's profile
(`.masc/playground/<name>/`, or `.masc/playground/docker/<name>/` for a Docker
Keeper) and the message names it bare.

A Keeper that has never run has no directory, and one is not created for it -
that would be this surface deciding something about the Keeper's own space.
Nor is a failed write hidden: both cases put the pasted text into the message
instead and say so in Recent Events. A paste that arrives as a large message
is worse than one read off disk; a paste that arrives as neither is the thing
this must not do.

`Ctrl-U` drops both. Switching Keepers puts the text back into the draft
first, so a saved draft never holds a placeholder whose text has gone.

Line breaks arrive as CR, LF, or CRLF depending on the terminal and on what
was copied; all three become one LF in the draft. Everything else that is not
printable becomes a space - a paste is the one way a terminal escape sequence
could reach a message, since typed keys are filtered one scalar at a time.

A paste over 1 MiB keeps the first 1 MiB. The rest is read - the end marker
has to be consumed, or the tail of the paste arrives as keystrokes - and
counted, and Recent Events says how many bytes are not in the draft.

#### Looking at an image

`/image <path>` draws an image file on the terminal, if the terminal can hold
one. The picture takes the whole screen, with the path above it, and the next
key press takes it away and repaints the frame - that key does nothing else,
so dismissing a screenshot cannot also move a cursor.

Whether the terminal draws pictures is asked once, before the first frame,
with the Kitty graphics protocol's own capability query. Terminals that
implement it (Ghostty, Kitty, WezTerm) answer; terminals that do not say
nothing, and `/image` then refuses in words instead of writing base64 onto the
screen. Inside tmux the escapes are wrapped for passthrough, which also needs
`allow-passthrough on` in the tmux config - that is the operator's setting and
the TUI cannot check it.

A path that cannot be read, or a file that is empty, is refused as a line in
the pane. Nothing takes the screen to report a failure.

#### Lines typed during a turn

Enter during a running turn is the explicit **queue next** action. It holds the
line for a later turn rather than pretending the running model saw it. Pending
input is not inserted between the active turn's user, status/tool, and reply
rows. It has its own `NEXT` lane below the causal transcript, oldest first:

```
   (sending tui-..d3530056 · 12s…)
   NEXT 1 · 10:42:13 · check the CI run too
   NEXT 2 · 10:42:18 · and the rebase
   > _
  Enter:queue (2 waiting)  Ctrl-K:cancel last  Ctrl-P:edit last  …
```

A count on its own is not enough - an operator who typed three lines during a
turn needs to see which three. Up to three pending items are shown (the first
two dispatch positions and the newest submission); a fourth row names how many
middle items are hidden so a full 32-item queue cannot consume the viewport or
disable cancel/edit. Each item keeps its first submission clock while it waits
and after it starts. Only the first line is shown; the rest goes with it.

`/steer <message>` is a distinct action. It signals the exact current request
ID to stop and places the replacement in a typed `STEER` row ahead of ordinary
`NEXT` rows for that Keeper. The replacement is dispatched only after the
current operation reaches a terminal state; an interrupt acknowledgement is
not misreported as completion. A second pending steer for the same Keeper is
refused instead of silently replacing the first.

If the stream disappears without terminal evidence, the row changes to
`reconciling` and the TUI re-subscribes with the same idempotent operation ID.
The Keeper remains occupied and every `NEXT`/`STEER` stays held until the
server emits a verified terminal receipt. A transport error is never treated
as a turn boundary.

A queued line travels with the keeper it was written to, so switching keepers
mid-turn cannot redirect it; a line addressed elsewhere names its keeper after
the number. The visible `NEXT` count is scoped to the selected Keeper rather
than the workspace-global queue. `Ctrl-K` drops the newest waiting line and
`Ctrl-P` edits it in place. Newest means submission sequence, not dispatch
position: editing preserves request ID, original submission clock, queue slot,
attachments, `NEXT`/`STEER` intent, and a steer's causal parent. Nothing has
been dispatched, so both are local.

When the oldest `NEXT` row becomes active, its reserved row is handed to the
active USER row one-for-one. The row therefore does not jump upward through an
older turn's Tool or reply block.

The arrows walk what the operator typed for this keeper, newest first, and the
waiting lines come before the sent ones. `Up` on a fresh composer therefore
hands back the line that is waiting rather than stepping over it into what was
already delivered. The draft is put aside on the first step back and returned
on the way forward past the newest.

A failed roster read blocks sending. When `.masc/keepers/` cannot be read
reliably, a stale entry may still name the target, so membership alone does not
authorize an external effect - the surface renders
`Keeper roster is unavailable` and the footer reads
`Enter:disabled (roster unavailable)`.

### Approvals

Operator approvals scoped to the acting actor.

```
 MASC Approvals (0/0, hidden 0, actor masc-tui)  10:55:48  [connected]
   (no pending approvals)
  j/k:move  y/y:confirm  n/n:deny  r:refresh  Tab:next  | Port: 8935
```

`y` and `n` post to `/api/v1/operator/confirm`. Selection is held by item
identity, so a refresh that reorders or drops items does not move the cursor
onto a different request.

### Board

Posts with their vote and comment counts. Right or `Enter` opens the body;
Left or `Esc` returns to the list.

```
 MASC Board (50)  10:44:52  [connected]
   order net votes first; newer breaks ties · s cycles ranking
 >   p-687c6844e~  polisher     [B1 mission draft v9] RW20 PoC scenario     +9  c39
     p-0323d8b3c~  dashboard    RFC-0370 Draft: rotation census             +4  c22
  j/k:move  Enter:read  r:refresh  Tab:next  | Port: 8935
```

Selection follows post identity across refreshes. Opening a post binds the
detail view to that post's request, so a late response for a post you already
left is discarded rather than rendered under the current title.

`s` cycles five server-owned rankings, with the active formula printed above
the table: `hot` is net votes descending with newer posts breaking ties;
`trending` is net votes divided by the square root of age in hours; `recent`
is newest creation first; `updated` is latest change first; and `discussed` is
reply count descending with newer posts breaking ties. Replies do not inflate
`hot` or `trending`. `f` cycles the hearth census shown on the next line, so
ranking and topic narrowing remain separate axes.

`w` on the list opens a new-post draft. The draft follows the commit-message
convention: the first line is the title, the rest is the body. `Enter` makes
a new line, and sending is armed rather than pressed - `esc` offers
`s:send d:discard`, so no stray key publishes. The post goes out under the
operator's agent identity; the server stamps the author. A rejected post
keeps the draft and shows the server's message.

`v` votes the row under the cursor up, `V` votes it down - the shift key is
the direction. Like every irreversible action here, the first press arms and
the same press again sends. In a post, `c` replies: the same compose pane
opens with the post as its target, the whole draft is the comment, and
sending returns to the post with the reply visible.

Board comments keep their author and timestamp on a separate line. Markdown
headings, lists, tables, code blocks, and wrapped paragraphs are rendered below
that line instead of being flattened into one truncated row. When a post or
comment body is a complete JSON object or array, Board pretty-prints it and
uses the same JSON syntax colours as fenced code. Ordinary Markdown remains
authored Markdown.

### Planning

Planning is one workspace with three ordered child views: `1 Goals` groups the
outcome and its linked Tasks; `2 Task Review` holds Task completion requests
waiting for an operator decision; `3 Evaluator Verdicts` shows automatic Gate
rulings recorded afterward; `4 Schedules` and `5 Fusion` keep their own
headers but continue the same walk. Press `v` to move through that order.
Evaluator Verdicts is the old Harness ledger, not a Goal completion proof.

```
 MASC Planning  ▸1 Goals  2 Task Review·2  3 Evaluator Verdicts  10:44:57  [connected]
   show executing + verifying · order phase order, then P1→P5
   Executing: 3  Paused/Blocked: 1  Verifying: 0  Done: 24  Dropped: 22
   Backlog: todo=4  claimed=0  running=6  done=109  cancelled=37
 >   [dropped ] P1  Reduce all kidsnote service backlogs to 0
     [executi~] P1  Multi-Keeper real-world mission keeper-collab-e0-r7
  j/k:move  Enter:detail  r:refresh  Tab:next  | Port: 8935
```

The cursor tracks goal identity in visible order, so a refresh that reorders
goals keeps the same goal selected.

`f` cycles `all`, `active`, `completed`, and `dropped`; active means exactly
Executing plus Verifying. `s` cycles `phase/P1-P5` (Executing, Verifying,
Completed, Dropped, then priority), `updated` (most recently changed first),
and `due` (earliest due date first, undated last). The current meanings are
printed above the rollup. Status colour and the proof marker remain independent
of ordering, so a row does not look successful merely because it sorted first.

Goal detail's `RELATED ACTIVITY` block is not a complete Task history. It shows
the latest state per linked Task and Keeper, pending approvals, and Goal phase
events. Task rows name the typed actor role (`claimed by`, `submitted by`,
`completed by`, or `cancelled by`) and the latest handoff author and summary
when present.

In a goal detail, `c` requests completion, `x` drops, `o` reopens. Each is
armed rather than pressed - the first press shows what the same key again
would send, any other key disarms - and the server owns the phase rules: a
transition the current phase does not allow comes back as the server's
rejection on the detail, not a local guess.

#### Task Review

Task Review is the queue of Tasks a keeper submitted for a verdict. The title
keeps it under Planning and the `Planning·N` badge keeps waiting work visible
from the top-level strip. It does not mean the same thing as a Goal's
`Verifying` phase: that phase belongs to the Goal proof agent; this queue is a
human/operator decision on Task evidence.

`a` on the row under the cursor arms an approval and the same key again sends
it. `x` rejects; the reason is required, so `$EDITOR` opens with a one-field
form. Both use the Task verification API and retain its admin permission
boundary.

### Schedules

The scheduled-automation list: every wake the runtime has queued, active rows
first by due time. This is the surface that answers "why is this keeper about
to wake up". It is the fourth stop of Planning's `v` walk rather than a Tab
stop; `v` moves on to Fusion, `Esc` returns to Planning, and the palette
keeps `go Schedules`.

```
 MASC Schedules  [me]  10:44:57  [connected]
   Requests: 34  (page shows first 20)
   Next due: 2026-08-24T09:57:00
 >   [scheduled] 2026-08-24T09:57:00  alpha        daily 09:57
     [running  ] 2026-08-24T09:12:00  sangsu       one-shot
  j/k:move  Enter:details  n:new  e:modify  x:cancel  r:refresh  Tab:next
```

The header count and the page are different things: the server sorts the whole
store active-first and serves the first twenty rows, so `(page shows first
20)` names what is held back. A store that could not be read is
`data unreliable` with the failing call, not an empty list - "the ledger is
unreadable" and "nothing is scheduled" are different facts.

`x` cancels the row under the cursor. Like every irreversible action here it
is armed: the first press names the schedule, the same press again sends it,
and the cursor moving between presses re-arms for the new row. Whether a row
is still cancellable is the server's store rule to decide - cancelling a row
that already ran comes back as the server's rejection on the surface, not a
local guess from the status column. The payload target column names who the
wake reaches (a keeper, for keeper wakes); rows without one fall back to the
payload summary.

`n` opens a JSON creation form in `$EDITOR`; `e` opens the selected row's
exact editable definition, including its full message, due time, recurrence,
expiry, urgency, and stable schedule id. Exiting the editor with zero sends
the form, while a non-zero exit changes nothing. The form keeps example fields
for interval, daily, and cron recurrence in place; `recurrence_kind` chooses
which set the server reads. Modification is one atomic
store transition: only `scheduled` or `due` rows can be replaced. It preserves
the public `schedule_id` but creates a fresh `schedule_instance_id`, so wake
evidence produced by the old definition is never shown as evidence for the
new one. Running and terminal rows return the server's explicit refusal.

Right or `Enter` opens the selected schedule. The detail includes schedule and instance
identity, dispatch state, requesting actors, timestamps, recurrence, payload
kind/tool/digest/summary, the pretty full payload JSON, last wake, and
queue/reaction evidence. Keeper wakes also show the durable Keeper,
stimulus/occurrence ids, every recorded step timestamp, and the projection's
exact failure or quarantine reason. This receipt proves wake delivery and
whether a turn started; it does not causally attribute later tool calls or a
work result to the schedule. The detail says so explicitly and points to
Keeper Calls or Activity for execution evidence after the recorded turn start,
instead of presenting an unrelated tool output as the schedule result. Left or `Esc` returns
to the list; `j`/`k` scroll by a row and `PgUp`/`PgDn` by a page.

### Fusion

The retained Fusion run registry is the list. It is the fifth stop of
Planning's `v` walk rather than a Tab stop; `v` wraps back to Goals, `Esc`
returns to Planning, and the palette keeps `go Fusion`. While a run is active, `STATE`
shows the exact process-local stage: `accepted`, `panel(N)`, `judge(A/F)`,
`computed(A/F)`, or `recording(A/F)`. A successful terminal row also carries a
bounded decision and resolved-answer preview when the current producer wrote
them; replayed legacy rows remain valid without that preview. The cursor
follows run id across refreshes, so a newly sorted row cannot silently change
what `Enter` opens.

```
 MASC Fusion (19 runs)  18:31:04  [connected]
   TIME     AGE     STATE              KEEPER           PRESET     RUN
 > 16:42:11 14s     judge(2/1)         rw-e0-r9         trio       kmsg-386bed...
   16:40:07 2m      completed          analyst          trio       kmsg-942ab1...
  j/k:move  Enter:detail  r:refresh  Tab:next  q:quit  | Port: 8935
```

The detail is a separate exact read. Lifecycle remains the Registry fact;
evidence comes only from a Board post whose typed origin is
`source=fusion` with the same `fusion_run_id`. The header repeats the current
stage and its panel counts. `recorded` puts the judge result, resolved answer,
and reason first, followed by the question and every panel answer or failure in
server order. Question, successful panel answers, judge resolution, reason, and
the terminal summary use the TUI Markdown renderer; typed failures stay plain
so their exact reason text is not reinterpreted. The panel header summarizes
answered/failed counts and tokens; it does not calculate a majority, minimum
answer count, timeout verdict, cost verdict, or any other local conclusion.
The open list and exact detail refresh on the existing two-second dashboard
cadence; `PgUp`/`PgDn` scroll a page at a time.

`TOOL EXECUTIONS` is an execution ledger, not a copy of the `web_tools`
configuration flag. `called` and `succeeded`/`failed` rows come from the exact
AGENT_CORE `ToolCalled`/`ToolCompleted` occurrence and retain actor, tool-use
identity, turn/index, tool name, bounded input/output previews, original byte
counts, and truncation state. `complete` with no rows means the instrumented
actors made no calls. The run ledger retains at most 256 events; EventBus or
run-ledger overflow increments the visible dropped count. `partial` names dropped rows and actors that
cannot publish this evidence; an official-client panel is shown as
`official_client_uninstrumented` instead of being misreported as “used no
tools.” Older Board evidence has `Trace unavailable` rather than a fabricated
empty ledger.

`pending` is legal only while the Registry row is running. `absent` means the
retained completed/failed run has no current Board projection; it does not
claim the post was never written, that the sink failed, or that retention
expired. A failed refresh leaves the prior reading visible under an explicit
error instead of redrawing it as an empty result.

### Memory

Keeper별 Memory OS 건강 상태를 한 표로 보여준다. ordinary current
snapshot과 source-bound snapshot을 별도 열로 표시하며, 각 행은 두 저장소의
revision, facts, 크기와 source invalidation 수, 최근 ordinary 변화
(+추가/-제거), 상태를 담는다. `STARVING`은 Librarian 실행이 실패했고 두
스냅샷 모두 없는 Keeper다. ordinary snapshot은 없지만 source-bound snapshot이
남아 있으면 `source-only`로 표시한다. 이는 source 근거가 남았다는 뜻이지
Librarian 선택이 성공했다거나 ordinary snapshot이 복구됐다는 뜻은 아니다.
`no-current`는 아직 ordinary snapshot이 없는 조용한 상태, `degraded`는
ordinary snapshot은 있지만 Librarian 갱신이 실패 중인 상태다. 두 저장소 중
하나라도 읽지 못하면 `read-error`로 표시한다.

상단의 `failed/no ordinary` 수는 서버가 `librarian_starvation`으로 판정한
Keeper 수다. 따라서 source-bound snapshot이 남아 `source-only`로 표시되는
행도 이 수에 포함될 수 있다. 표의 상태는 남아 있는 저장소를 말하고, 경고
색과 상세 alert는 Librarian 실패의 서버 severity를 그대로 보존한다.
Vision ingest 오류가 있으면 상세에 구조화된 reason별 횟수를 표시하고, 해당
행을 warning으로 그린다. 이미지가 text placeholder로 대체된 실패를 정상
ingest로 보이지 않게 하기 위함이다.

커서가 가리키는 행의 전체 상태와 서버가 매긴 경고(alert) 목록이 표
아래에 함께 나온다. `r`로 다시 불러온다.

행에서 `Enter`를 누르면 그 Keeper의 **사실(fact) 브라우저**가 열린다.
표가 개수만 말하던 것을 사실 단위로 보여준다: ordinary 저장소의 각 사실은
`[category] 내용 ×강화횟수`로, source-bound 사실은 `[source] 경로 — 내용`
으로, 무효화된 사실은 `[dropped] 경로 — 사유`로 그린다. category와
origin, 무효화 사유는 서버가 보낸 문자열 그대로다 — TUI는 분류를 만들지
않는다. 커서 행의 전체 내용(원문, origin, 강화 횟수, first/last seen,
memory id, source sha)은 목록 아래에 펼쳐진다.

`c`는 category 필터를 순환한다: All → 로드된 저장소가 실제로 가진
category들(정렬순) → All. 필터는 ordinary 사실만 좁힌다 — source-bound
행은 category가 없으므로 항상 보인다. `/`는 사실 내용으로 커서를 옮기고,
`Esc`는 건강 표로 돌아간다. 두 저장소는 서버가 따로 답하므로, 한쪽이
읽기 실패해도 다른 쪽 목록은 그대로 나오고 실패한 쪽은 사유가 화면에
남는다.

### Workspace

등록된 저장소와 서버가 실제로 해석한 체크아웃 경로를 보여준다. Tab 링의
정거장이며, Code 화면은 이 화면에 매달린 자식이다. 목록의
`Path` 열은 폭이 부족하면 가운데를 줄여 표시하지만, 선택한 행 아래의
`Path:`에는 전체 경로가 줄바꿈되어 나온다. 설정에 저장된 값이 상대 경로라면
`Stored as:`가 함께 표시되고, 담당 Keeper는 `Keepers:`에서 확인할 수 있다.

Right 또는 `Enter`를 누르면 선택한 저장소 범위의 Code 화면으로 이동한다.
`d`를 누르면 선택한 저장소의 현재 Git 변경 파일을 연다. 각 행은 staged,
worktree, untracked, conflict 상태를 구분한다. 이 목록에서 `Enter`를 누르면
해당 파일을 저장소 범위의 Code 화면에서 연다. Left 또는 `Esc`는 저장소
목록으로 돌아간다.

저장소의 Git 변경 사항과 Keeper가 남긴 작업 기록은 서로 다른 정보다.
아래 Changes 화면은 선택한 Keeper가 지난 24시간 동안 남긴 기록을 보여준다.

### Changes

Changes follows the Keeper selected on the Keepers surface. `[` and `]` move
that selection directly from Changes and reload the 24-hour change window;
the header always names whose rows are shown. Right or `Enter` opens the
selected recorded diff, and Left or `Esc` returns without moving the cursor.

`v` opens the row's file on the Code surface, read through the keeper's own
workspace (`?keeper=`), so the bytes are the keeper's checkout rather than a
same-named file in the project tree — and the jump aims at the changed line
when the local copy can say where it is. `o` hands the file to `$EDITOR` /
Neovim instead. An absolute-path write has no address inside the keeper's
workspace, so `v` says so and leaves that row to `o`.

### Code

A file browser over the workspace the server serves, one directory level at
a time (the tree route is lazy). Each row carries a one-column type mark: a
folder shows `▸`, and a file shows a glyph coloured by its extension — `◆`
code (cyan), `▤` data or config (yellow), `≡` prose (green), `»` script
(magenta), `◈` web or style (blue), `▨` media (magenta), `·` anything else
(dim). The glyphs are plain unicode, so no patched font is needed; under
`NO_COLOR` the glyph stays and the colour drops. `j`/`k` move the cursor,
`/` jumps it to a matching entry, Right or `Enter` drills into a directory or
opens the file,
and Left or `Esc` walks back out the way Enter came in. With a file
focused, `/` searches the file's own lines instead of the tree — typing
moves the line cursor to the first match, Enter keeps the query for
`n`/`N`, and the view follows the cursor.

Which workspace is a scope the header always names: the project tree by
default, a keeper's playground after a Changes `v` jump (`alpha ▸ repos/…`),
or a registered repository after `Enter` on a Workspace row
(`masc ▸ /`). `Esc` at a scoped root returns to the project tree, and at the project
root it lands on Workspace, the ring parent. The three
scopes are one field, so the surface cannot read two workspaces at once.

프로젝트 tree에 초점이 있을 때 `d`를 누르면 현재 프로젝트의 Git 변경
파일을 모두 보여준다. 이 프로젝트는 Workspace에 등록되어 있지 않아도
된다. 목록은 staged, worktree, untracked, conflict를 구분하고, `Enter`로
선택한 파일을 연다. Left 또는 `Esc`를 누르면 같은 프로젝트 tree로
돌아간다. 파일 pane에 초점이 있을 때의 `d`는 아래처럼 그 파일 하나의
diff를 연다.

An open file arrives whole and is lexed once — OCaml (nested comments
included), bash, JSON, the curly-brace family (TypeScript/JavaScript,
C/C++, Go, Rust, Java, and their kin: `//` and `/* */` comments, strings,
numbers, keywords), and Python (`#` comments, triple-quoted strings)
colour; an extension without a lexer draws plain, and a file past 500 KB
draws plain rather than slowly. The pane then answers three more questions
in place:

- `h`/`l` pan sideways by one display cell — the gutter stays put, the
  title says `(col N)`, and a double-width glyph on the boundary pads
  rather than splits.
- `H` swaps the content for one newest-first timeline: commits from
  `/api/v1/git/log` and durable Keeper `Edit`/`Write` calls from
  `/api/v1/ide/file-activity`. The latter is filtered by the exact registered
  repository id and repo-relative path; it does not revive the removed,
  always-empty IDE region store. The coverage row states the trailing window,
  exact match count, exact-address rows whose truncated/malformed body could
  not be rendered, and fleet rows that lost even their address. `Enter` on a commit answers with its pull
  request link (the subject's `(#N)` against the registered remote). `Enter`
  on a Keeper change returns to the file at its producer-recorded line. A
  project tree is joined automatically only when the server base path exactly
  matches one registered repository's resolved path; otherwise it keeps Git
  history and explicitly says why Keeper activity cannot be joined.
- `d` swaps it for the working tree's diff against HEAD, drawn by the same
  renderer the Changes surface uses. A clean file says it matches its last
  commit.

- `m` swaps it for the notes anchored to the file — who left each one, its
  kind, the line span, and the task it rides with. Notes are keyed by the
  server-minted codebase slug, which only a Workspace row carries, so
  `m` answers in repository scope and says why not in the others. Inside
  the notes view `w` adds one through the `$EDITOR` form (kind: Comment /
  Decision / Question / Bookmark); the acting identity is the bearer's.
- Once notes or history have been read (`m` or `H`), their exact producer
  ranges mark the gutter: an accent dot for a note, a dim dot for a durable
  Keeper change. Historical changes without line evidence remain in the
  timeline as `L?` and do not invent a range. The pane decorates only what is
  already loaded; it does not fetch to decorate.
- `K` asks the language server what a name on the cursor line is, and `D`
  where it is defined. The line's own names are the candidates (the pane
  has no character cursor): one name is asked about at once, several open
  the palette with each as an entry — typing narrows them, `Enter` runs
  the highlighted one, and a typed `def <name>` still works — and a line
  with none says so. The answer lands beside the title, and a definition
  inside the workspace moves the cursor there — another file opens at the
  answered line, and a location outside the workspace (stdlib, a package)
  is named rather than opened. The reverse-video gutter is the cursor
  line, which is what the question is asked about.

One overlay at a time — opening any of them closes the others, so
`j`/`k` always has one owner. `Esc` closes the overlay first, then the
file, then climbs directories.

### Tools

The Tools surface hangs off Config under `t` and has five panes. Press `p` to move through the selected
Keeper's effective Tool surface, async requests, Skill activations, cross-Keeper
Skill usage, and the registered Tool catalog. This keeps the Skill views from
being buried below a long Tool list.

The Skill Usage pane shows each Keeper's invocation/delivery/action counts and
the producer-recorded `last_used_at` value. If retained usage coverage has no
time, it says `time unavailable`; it does not turn bounded evidence into a
`never used` claim.

### Runtime

Runtime lanes and their ordered candidates, joined to the latest provider
metadata reachability reading by exact `runtime_id`.

```
 MASC Runtime (43 lanes, 46 candidates)  degraded / stale  19:20:04  [connected]
   SSOT: runtime.toml  projections: resolved + probe  2 reachable / 16 failed / 28 skipped
   LANE           CANDIDATE                  PROVIDER / MODEL         ROUTE / PROBE
   primary        1/3 anthropic.opus         Anthropic / claude-opus ready / reachable
   local          1/1 local.codex            Codex / codex           ready / CLI not probed
```

The authority is `runtime.toml`, read through two server-owned views.
`GET /api/v1/runtime/resolved` projects lane order, candidate identity,
provider/model labels, dispatchability, and sticky preference. The sticky
timestamp means **last successful
candidate**, so the row says `last success`; it is never presented as failure
history. `GET /api/v1/dashboard/runtime-probe` supplies only a cached provider
metadata-endpoint reachability reading. It does not send a completion, execute a CLI
runtime, or report lane failover history.

`CLI not probed` is neutral, and a candidate absent from a stale probe is
`unobserved`, not unhealthy. Green is limited to the `reachable` token; model,
provider, and ordinary row text use the terminal foreground. A blocked route,
probe failure, and missing authentication remain distinct typed states.

The freshness badge is the server's closed value: `fresh`, `recent`, `stale`
(`served_stale` on the wire), or `warming` (`warming_up`). `r` sends
`force=1`, but the route remains non-blocking: a stale or warming response
means background work was scheduled and a later poll carries the new value.
Only one joined load may be in flight, so a slow authenticated request cannot
stack every two-second refresh tick. A manual refresh pressed during a periodic
read is coalesced into one force request when that read settles. If only the
probe read fails, resolved lanes still render: a last-good probe is retained,
or cold candidates are `unobserved`. If the resolved identity read fails, the
last joined rows stay visible under the error.

`j`/`k` selects a row in both `Lanes` and `All runtimes`. Right or `Enter`
opens an untruncated detail view bound to that exact runtime identity. It shows
the complete runtime id, provider and model, every lane using it, candidate
position, dispatch blocker/default state, last-success timestamp, and the
probe's status, transport, timestamp, latency, HTTP result, and error when
those observations exist. `PgUp`/`PgDn` pages the detail; Left or `Esc` returns
to the same list row.

### Config

Config is five views over the runtime's settings. Press `p` to move through
`runtime.toml`, `models`, typed `params`, prompt overrides, and themes.

The `runtime.toml` view keeps comments and section headings on screen, while
`j`/`k` select only rows that contain actual assignments. `PgUp`/`PgDn` jump
by a visible page and land on the nearest assignment. The selected row is a
full-width band, so navigation always has a visible position.

Models is a read-only index over the same file. It puts each binding's
`reasoning-effort`, `temperature`, and provider `max-tokens` beside the model
name; `-` means the key is genuinely absent, not that an empty value was
loaded. The selected-row detail names the effective API model and the exact
owning sections: effort and temperature belong in `[models.NAME]`, while the
token cap belongs in `[PROVIDER.NAME]`. Thus adding only an effort is a
one-line change under the named model section; copying a sibling block is not
required. `e` returns to that `[models.NAME]` section in `runtime.toml`, whose
preview-checked editor remains the one write path. Params are different: they
come from the typed live registry, and
`Enter` edits one value while `x` restores its registered default.

Prompt overrides open as a reduced operator catalog: the six complete prompts
for Keeper, Librarian, verification, and judges are visible by default. The
other fourteen files are still live, editable assembly fragments; `a` toggles
them into the list without presenting headings and row snippets as complete
prompts. The list uses Korean category and purpose labels, while exact keys and
template-variable names remain unchanged. The detail pane renders the effective
body as Markdown (including fenced-code syntax highlighting), names whether it
came from a file or an override, and keeps `PgUp`/`PgDn` paging. `e` edits the
effective prompt through `$EDITOR`, and `x` clears only its persisted override.

### System Logs

The log browser hangs off Activity under `l`; Esc returns there.

The server's log ring, the same source the dashboard `logs` tab reads.

```
 MASC System Logs (247 of 774273, seq 774272)  level≥INFO  verbose:off
   Time     Level   Module           Keeper       Category  Message
   03:09:21 INFO    Discord          system       routine   presence update: idle
   03:09:18 WARN    Keeper           alpha        turn      turn budget exceeded
   03:08:57 ERROR   Board            system       boundary  board post write failed
```

The first count is what the fetched page shows after its category filter;
`774273` is what the ring has seen. A page count on its own would read as
"that is all there is".

`v` toggles verbose DEBUG rows directly: off uses the INFO floor and on asks
the server for every level. The header always says `verbose:on` or
`verbose:off`. `l` remains the full server-side floor ladder through INFO,
WARN, and ERROR, then opens back to every level; changing either control
refetches the page. `c` cycles `all` and
each category observed on the loaded page. Right or `Enter` opens the exact
sequence under the cursor with its untruncated timestamp, level, category,
source, module, keeper, turn, message, and pretty syntax-highlighted JSON
details. `[`/`]` steps through adjacent visible entries while detail is open;
Left or `Esc` returns to the filtered list.

Levels are coloured: `ERROR` red, `WARN` yellow, `DEBUG` dim. A level the
server emits that this build does not name keeps its own text and renders
unstyled, so it shows up as itself rather than as an ordinary line.

When the load fails the previous page stays on screen under a red line saying
so. The count above it is then stale, not a fresh reading.

## Keybindings

Cross-surface shortcuts. An active field or panel handles its own keys first:

| Key | Action |
|-----|--------|
| `Tab` | Next surface, in the ring order the strip draws |
| `2` | Jump to Keepers when the active field or panel does not use the number |
| `r` | Force refresh |
| `q` twice | Quit; any other input after the first `q` cancels |

Per surface:

| Key | Surface | Action |
|-----|---------|--------|
| `j` / `k` | Overview | Scroll Recent Events |
| `j` / `k` | Keepers, Lanes, Approvals, Board, Planning, Schedules, Fusion list | Move cursor |
| `j` / `k` | Runtime, System Logs | Move the list cursor; scroll when detail is open |
| `j` / `k` | Keeper detail, logs, Board read, Planning detail, Fusion detail | Scroll content |
| Right / `Enter` | Keepers | Open keeper detail |
| Right / `Enter` | Lanes | Open the selected standalone lane's exact runs |
| `c` / `m` | Lanes | Explain that standalone lanes have no Keeper chat target |
| Right / `Enter` | Board | Open post body |
| `Ctrl-W` | Board read, Resources | Switch the focused pane |
| `[` / `]` | Resources detail | Open the previous / next resource |
| `h` / `l` | Wide Board read | Focus post list / post detail |
| `PgUp` / `PgDn` | Board, Schedules, Fusion, System Logs detail | Move the active list or detail by a page |
| Right / `Enter` | Schedules | Open schedule details |
| Right / `Enter` | Planning | Open goal detail |
| Right / `Enter` | Fusion | Open exact run evidence detail |
| `[` / `]` | Changes | Previous / next Keeper |
| Right / `Enter` | Changes | Open the selected recorded diff |
| `v` | Changes | View the row's file on the Code surface, in the keeper's workspace |
| `a` twice | Verification | Approve the row under the cursor |
| `x` | Verification | Reject it, with a reason through `$EDITOR` |
| Right / `Enter` | Workspace | Browse the repository's tree on the Code surface |
| `d` | Workspace | Show the repository's current Git working-tree changes |
| `d` | Code, project tree focused | Show every Git change in the current project, even when it is not registered |
| Right / `Enter` | Code | Drill into a directory / open the file |
| Left / `Esc` | Code | Close the overlay, then the file, then climb a directory; `Esc` at the project root leaves for Workspace |
| `/`, `n` / `N` | Code | Jump the tree cursor to a match |
| `h` / `l` | Code, file open | Pan the file sideways by one cell |
| `H` | Code, file open | The commits that touched the file, newest first |
| `d` | Code, file open | The working tree's diff against HEAD |
| `m` | Code, file open, repository scope | The notes anchored to the file |
| `w` | Code, notes view | Add a note through the `$EDITOR` form |
| `K` / `D` | Code, file open | Ask the language server: hover / definition of a name on the cursor line |
| `l` | Keeper detail | Open logs |
| `Enter` | Memory | Browse the selected keeper's facts, both stores |
| `c` | Memory facts | Cycle the category filter through the loaded categories |
| `Esc` | Memory facts | Close the browser, back to the health table |
| `c` / `m` | Keeper list or detail | Open message input for the selected keeper |
| `y` / `n` | Approvals | Confirm / deny the selected request |
| `n` | Schedules | Create a schedule through the `$EDITOR` JSON form |
| `e` | Schedules | Modify the selected active schedule atomically |
| `x` | Schedules | Cancel the selected schedule (armed: same key again sends) |
| `e` | Keeper list or detail | Edit the selected keeper's settings in `$EDITOR` (JSON patch; only the fields you keep in the file are sent). Exit 0 sends, any other exit changes nothing |
| `a` | Keeper list or detail | Create a keeper: a declaration stub opens in `$EDITOR`; the `name` field in the file names the new keeper |
| Left / `Esc` | any structural detail or logs view | Back one level; Left never interrupts chat |
| `Enter` | Message | Send |
| `Ctrl-G` | Message | Switch to the next Keeper while no turn is in flight |
| `Ctrl-U` | Message | Clear the input line |
| `Backspace` | Message | Delete the last UTF-8 scalar without splitting its byte encoding |
| `PgUp` / `PgDn` | Message | Scroll chat history by a page |
| `Up` / `Down` | Message after scrolling back | Adjust chat history by one line |

## Navigation

```
Tab cycles the surfaces:

  Overview -> Activity -> Keepers -> Memory -> Approvals -> Board
           -> Planning -> Workspace
           -> Runtime -> Config -> Overview

Within a surface:

  Keepers   --Right/Enter-->  Keeper detail  --l-->  Keeper logs
  Lanes     --Right/Enter-->  Standalone exact runs

  Keeper list/detail  --c-->  Message input

  Board     --Right/Enter-->  Board read
  Planning  --Right/Enter-->  Goal detail
Off-ring children:

  Planning  --v-->  Task Review --v--> Verdicts
  Keepers   --f-->  Changes
  Keeper detail --[ / ]--> Channels / Automation / Runs
  Runtime   --p--> ... --p--> Lanes
  Workspace --Enter-->  Code (the selected repository's tree)
  Config    --s-->  Resources        Config --t--> Tools
  Activity  --l-->  System Logs
```

`2` reaches Keepers after the active field or panel has declined it.
`Esc` returns one level within Keepers, Board, and Planning.

## Requirements

Interactive TTY stdin and stdout, and a terminal other than `dumb`.

Rendering is input-driven: a frame is produced after input, an applied refresh
or result, or a terminal resize. Background changes are coalesced into 16 ms
windows and only changed viewport rows are written. An idle TUI neither redraws
nor re-probes the terminal size.

Each non-empty paint is sent as one synchronized-output update (CSI 2026) so
terminals supporting the protocol reveal the frame atomically. `MASC_TUI_SYNC=off`
omits that envelope; row-diff correctness does not depend on protocol support.

Apple Terminal uses a conservative profile because it does not advertise the
optional synchronized-output or Kitty keyboard protocols. Synchronized output,
Kitty keyboard mode, and dynamic OSC window titles default off when
`TERM_PROGRAM=Apple_Terminal`; `MASC_TUI_SYNC=on`,
`MASC_TUI_KITTY_KEYBOARD=on`, and `MASC_TUI_TITLE=on` explicitly opt them back
in. Other terminals keep the existing defaults, and each setting also accepts
`off`.

Exit signals restore terminal modes and cursor state. Job-control suspension
(`Ctrl-Z`) restores the shell terminal, and `fg` re-enters raw mode and forces a
complete repaint.

Viewports below the fixed chrome budget render a compact resize gate instead of
a clipped frame, and message editing is suppressed until the terminal grows.

## Troubleshooting

**Header shows `[disconnected]`.** The server is not answering on
`127.0.0.1:<port>`. Keepers and the Tasks panel keep working; Approvals, Board,
Planning, Fusion, and messaging do not. Check the port with `--port`.

**Keepers list is empty but the runtime is running.** The base path is probably
wrong. The list reads `.masc/keepers/` below `--base-path`, with no server
involved, so an empty list with no error means the directory is empty.

**Tasks panel prints `task backlog unavailable`.** The message carries the full
path, but it does not tell you whether the file is missing or malformed. A
missing key currently reads back as an empty JSON object, so an absent
`.masc/tasks/backlog.json` surfaces as the schema complaint
`backlog must contain exactly one tasks list, last_updated string, and positive
version`. Check that the path exists before treating it as a schema problem.

**A surface says `(not loaded yet)`.** Nothing has been read for it: the
request is still out, or the surface was opened before a server was reachable.
It is not an empty result. A read that came back with nothing says so in its
own words - `(nothing waiting on a verdict)`, `(no verdicts recorded)` - and
only after the header has stopped saying `(not loaded)`.

**Keepers shows `- unread` in the STATUS column.** The live roster at
`GET /api/v1/gate/keepers` has not been read for that keeper - the first load
is still out, the read failed (the reason is printed above the list), or the
roster came back short and did not carry that keeper. It is not a status the
keeper is in. The header's `N unread` counts the same rows.

**A surface shows a count of `0` next to `data unreliable`.** The read failed;
the count is not an observation. The failing call is printed on the same row and
recorded in Recent Events.
