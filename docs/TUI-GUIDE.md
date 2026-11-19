---
status: runbook
---

# MASC TUI Guide

Terminal UI over a MASC runtime root. It reads `.masc/` directly and, when a
server is reachable, adds the surfaces that only exist over HTTP. Operations is
the first screen. It opens the decisions and conversations that need the
operator. The full Goal and Task lists are under Work; provider quota scopes,
Keeper costs and tokens, and daily provider reports are under Usage
(Operations `m`). Board is under Work with an explicit `: go Work / Board`
palette destination. Activity and server logs are under System (`A` / `L`).
The [operator information architecture](design/tui/OPERATOR-INFORMATION-ARCHITECTURE.md)
defines the reading order and observation boundaries.
The [screen inventory](design/tui/SCREENS.md) lists all surfaces, subviews and overlays.

Header clocks and ordinary row times use the terminal's timezone. Usage trends
and Task completion days are explicitly labeled UTC.

New here? The [first 30 minutes](../docs-site/src/content/docs/getting-started/first-30-minutes.md)
chapter walks from install to your first Task and Board post, one signal at a
time.

## What can I do here

Type `/features` in any composer and the feature sheet lists what this TUI
can do — one sentence per feature, beside the command, key or name that
opens it (`/keeper <name>`, `Ctrl-L`, `masc_tool_help`, ...). Names are wire
names, so a row can be copied and typed as it is printed. The key-level
reference is `?` in the TUI; `/help` lists the slash commands.

Opening `:` with no search shows the six main destinations. Type a screen,
Keeper, Task, post or setting name to find other actions. Detail screen names
include their parent, for example `go Work / Task Review` and
`go System / Runtime`. Short searches such as `go Task Review`, `settings`,
`go Connectors`, `go Collab` and `go Play links` select the same actions
without adding duplicate entries.

## Quick Start

For human contributors building from source:

```bash
dune build --root . bin/masc_tui.exe
./_build/default/bin/masc_tui.exe --base-path ~/me
```

`.masc` must live directly below the path you pass. An installed build is
`masc-tui`.

Point it at the same root the server uses. A TUI reading one root while the
server writes another shows stale keepers with no error, because both roots are
valid on their own.

## UI language (Experimental)

Switch selected TUI navigation and System/Configuration labels between Korean
and English while the TUI is running. From navigation, press `:` to open the
command palette, type `language` (`:language`), select
`language: English` or `language: 한국어`, and press Enter.
Searching for `언어` also finds these choices.

The System sub-navigation bar also offers a clickable `[언어:KO 전환]` /
`[Lang:EN toggle]` control. The System `Themes` (`테마·언어`) pane has a
clickable `UI 언어` / `UI Language` control too. Each click switches to the
other language. Use the palette when the control is clipped or terminal mouse
input is unavailable; changing the display language needs no server connection
or operator credential.

This Experimental setting covers the top-level navigation, Configuration tabs,
and selected System labels and detail headings. Each of those surfaces shows
one language only. It is a partial UI translation:
other text can remain Korean, English or bilingual after a switch. Keeper
messages, original content, command names and configuration keys keep their
original text.

To turn off English, select `language: 한국어` or click the language
control again. The choice is stored as `[tui].language` in `runtime.toml`,
so it is still there on the next start. An absent key starts in Korean,
and an unknown stored value is named in the event log:

```toml
[tui]
language = "en" # or "ko"
```

If the file cannot be written, the language still applies for this session and
the event log says which of the two happened.

## Browser

Use `:`, then `go Browser Lane` (or `B` from Connectors). `[` / `]` choose
among open tabs and `r` refreshes. Live reads use the cookies of the operator's
ego lite profile.
See the [Browser guide](guides/tui-browser-lanes.md) for setup and controls.

To revisit what a Keeper read, select that Keeper, open Browser Lane, and press
`h`. The observation list comes from that Keeper's 100 most recent tool calls.
`[` / `]` choose a saved page, `j` / `k` scroll it, and `y` copies its receipt
and artifact reference. `h` or `Esc` returns to the browser. Saved pages remain
readable after the browser closes; `h` also works from the browser picker.
`Tab` / `Shift-Tab` leave the reader for the next / previous MASC surface.
The MASC server must be running to fetch these records.

## MSX

Open Collab with `&` or `:` then `go Collab`. `m` watches MSX and `d` watches
DOS directly, including an empty machine's status. `Esc` returns to Collab.
Observation reads the shared screen without advancing the machine or sending
keys. MSX's `F5` explicitly switches between observation and control; only
control sends game keys, advances frames, or offers checkpoint/disk actions.
Control and game changes require a verified server matching the TUI's local
workspace. Losing that authority closes the machine view and clears control;
returning to the same workspace requires a new explicit control action.

`g` in Collab (also `:` then `go MSX`) takes the terminal over with the workspace MSX
machine: a load menu first, listing the cartridge images in the MSX
Add-on's volume, then the screen of the game a Keeper or you
loaded. Entering this picker resets to observation, so `Esc` back to a loaded
screen does not resume earlier control. The `F8` disk picker keeps the current
control mode. The volume starts empty and the menu says so; when the Add-on
cannot be reached the menu says the list is unavailable and gives the reason.
The [MSX cartridges runbook](operations/msx-carts-runbook.md) says how an
operator places images in the volume, what the machine accepts and where the
images come from.

## Shared DOS machine

Open `:` then `go DOS` to watch the same live DOS screen an invited player
sees at `/play`. The TUI view is a spectator: `Esc` returns and `+`/`-`
resize it; game input and turn changes go through the server's controller.

## Shared DOS play invites

In Collab, `n` asks for a player name and expiry hours, then issues a link.
`j`/`k` select an invite, Enter opens its locally retained QR/link, `x` asks
to revoke the selected invite, and `r` refreshes the inventory. This needs
no selected Keeper. `:` then `go Play links` opens the same screen.
`q` or `Esc` closes Collab.
Invite forms and writes require the server to match the TUI's local workspace.
Observation and inventory reads remain available when it does not match.
If a request loses its response or workspace authority, its outcome remains
unknown for its original workspace.
The TUI durably records the origin and request before dispatch in the local
workspace's `.masc/tui-play-pending.jsonl`; restarting retains unresolved
changes as unknown. An unreadable
recovery journal refuses further changes instead of assuming none are pending.

The Keeper chat composer also accepts `/play invites` to list invites, `/play invite <name>
<hours>` issues one, `/play link` reopens the latest link issued in this TUI
session, `/play link <name>` reopens an earlier link issued in this TUI
session, and `/play revoke <name>` removes it. Issuance requires
an admin operator credential, token-required authentication and
`MASC_HTTP_BASE_URL`. A refusal shows the server's own sentence and what it
says is missing, for example when auth is off or `require_token` is false.
The server's default address is local. A link beginning with `localhost`,
`127.*`, `::1`, or an IPv4-mapped loopback address works only on that computer; the card explains this before
sharing. For another device, configure the server launch's `MASC_HTTP_BASE_URL`
to an address it can reach through the listener or an authenticated reverse
proxy. Changing the TUI connection address does not change issued links.

The server shows the link once, so it goes on a card with a QR code and
nowhere else: not the chat, not the footer, not the session log. `y` copies
the link to the terminal clipboard through OSC 52; terminal clipboard support
varies, and `F2` still hands the mouse back so the link can be selected
from the card. `Esc` or `q` closes the card. `/play link` opens
the card again. The TUI keeps issued cards until it exits or their invites
are revoked. Only one invite request runs at a time: a `/play invite` sent
before the answer to the last one has come back is refused, not queued.

The QR is drawn only when all of it fits. A smaller window shows the link and
the size the QR needs, because a cut QR scans as nothing. With `NO_COLOR` or
on a terminal with fewer than 256 colours the card shows the link alone. A card
taller than the window scrolls with `j`/`k`, the arrow keys or the mouse wheel,
and `g`/`G` jump to its top and its end, so a long link can be read to its last
byte.

For an unknown outcome, first establish that the original server request
cannot still finish later: inspect its completion in server logs, or stop that
server process before restarting and inspecting the final invite state. An
inventory read alone can race a delayed write and is not completion evidence.
Then open Collab, press `u`, and explicitly confirm that check to permit further
changes. Restarting the TUI does not bypass this check. If an issue's one-time
link was lost, revoke its confirmed final invite before issuing another.
A definitive revoke reply reporting controller-release failure may be retried
with `/play revoke <name>`; a second request can release a controller after the
invite credential was deleted.

The invited person opens the link in a browser to watch and play the shared
DOS machine. The link can also go to an AI agent (Claude Code, Codex, Hermes,
OpenClaw, pi, ...): the page points it at `/play/agent.md`, which says how to
join over MCP (`/mcp/play`) or plain HTTP with the token after `#`.

## Options

`masc-tui --help` lists the options: `--base-path` (`--base`), `--port`,
`--workspace`, `--reasoning` (default `folded`) and `--tool-view` (default
`compact`), plus `--version` and `--build-commit`.

## What the server changes

The TUI runs without a server. Keepers and Work Tasks read `.masc/` and work
without one. Every other surface needs it, except the TUI session block, which
records this session's own events.

An unreachable server is reported, not hidden. The header shows
`refresh failed`, the surface prints the failing call, and each failed load
lands in the TUI session block, under Usage → Telemetry (`p`, then `1`).

A count of `0` next to `data unreliable` means the read failed. It does not
mean the board is empty.

### When nothing answers

When every read fails because nothing listens on the port, the TUI starts a
server once per session: `masc start --base-path <base> --host 127.0.0.1
--port <port>`, with the `masc` beside the TUI binary, or else the one on
`PATH`. The server keeps running after the TUI closes. While the header says
`refresh failed`, `s` on the Keepers list starts one by hand.

The server's stdout and stderr go to `.masc/logs/masc-server-<port>.log` under
the base path, emptied at each start. When a server refuses to start before its
own log exists, that file is the only place the reason is written. The TUI
reads its last line back when the server exits before `/health` answers.

The TUI session block cuts each event at the frame width, so open
the file to read a long line whole. If the server is still not answering
after 30 seconds, the TUI says `masc server did not answer /health in time` and names the same
file.

## Navigation

Every surface draws the Tab ring on its top row with the active surface
highlighted; narrow terminals window the strip around the active entry and
show how many entries hide past each edge (`‹4`, `5›`).

`NO_COLOR` (non-empty) suppresses colour; borders, markers, and the
reverse-video selection stay. `MASC_TUI_FORCE_COLOR=1` overrides.

The System surface's Themes pane picks a bundled base16 scheme (monokai,
solarized, and others). Moving the cursor previews a scheme, `Esc` puts back
whatever was in force, `Enter` keeps the pick and `x` withdraws it.

A kept pick is written to `runtime.toml` under a `[tui]` table, which the TUI
reads at boot, so it is still there on the next start. The same key can be set by hand, and an absent or unknown name
follows the terminal:

```toml
[tui]
theme = "monokai"
```

If the file cannot be written, the scheme still applies for this session and
the event log says which of the two happened.

The opening surface can also be selected in `runtime.toml`:

```toml
[tui]
opening = "keeper" # or "last" or "overview"
opening_keeper = "alpha"
```

An absent `opening` or `overview` starts on the Dashboard. `keeper` opens the
named Keeper's chat; it needs `opening_keeper`. `last` opens the most recent
explicitly visited chat target from `last_chat_keeper`. If the target is unavailable, the TUI starts on the Dashboard
and shows the reason near the top. An invalid opening setting also starts
on the Dashboard with a reason.

`/about` shows the registered Keepers gathering beside the candle, then
settling into a still roster after about two seconds. Set `reduce_motion` to show that frame immediately.

The candle has two styles. `painted` is a 2D portrait with a flickering flame;
`dotted` is a small figure in square dots. `c` on the settled `/about` screen
turns the candle to the other style and stores it; an absent key is `painted`,
and an unknown one is named in the event log:

```toml
[tui]
candle = "dotted" # or "painted"
reduce_motion = true # optional; default false
```

The Keeper roster starts closed. At 110 columns and wider, `Ctrl-B` pins it
beside the current surface with the cursor marked. Narrower terminals use
the single-pane layout.

From Dashboard (Overview), press `Left` to open the Keeper list. In chat,
`Left` opens it only when the input is empty and its cursor is at the start.
With text present, `Left`/`Right` move the editing cursor; typing, paste,
Backspace and Ctrl-W edit at that cursor. Even at the start of a nonempty
draft, `Left` stays in the input. Use `Ctrl-G` to switch Keepers with a draft.
In the list, `Up`/`Down` (or `j`/`k`) select a Keeper; `Enter` opens its chat.
`Right`, `Esc`, or `Tab` returns to the screen you were reading without sending
a message or interrupting the Keeper. Chat drafts stay with their Keeper when
you switch. `Left` also opens a list hidden with `Ctrl-B`, without changing
that visibility preference.

### The Activity pane

`Ctrl-L` walks the pane on the right of eligible surfaces through narrow, wide
and hidden. Activity and Logs keep this pane off, since it would repeat their
own stream, and so does an open modal or the browser lane. On eligible surfaces
the pane opens
only where the surface keeps the width the Keepers list needs for its flag
columns -- 102 columns: from 158
columns for the narrow pane and from 176 for the wide one. Below that the
surface has the whole terminal. Its `[Recent]` tab is what each keeper is doing now, one row
each.

The mark is the keeper's health, as on the roster. `state` is the record the
feed has: `open` (no end event yet), `done`, `no end` (the process is gone,
so no end will come), `approval` (waiting on you), or `no events`. An open
record names the tool it is in and counts the calls seen *so far*, which is
what the `+` says: the feed may have started mid-turn. A done record carries
the turn's calls and its new tokens (`new tok`): in and out summed, cache
reads left out, so a cached turn shows what it processed fresh. The header says the feed only when it is not delivering
(`no feed`, `feed opening`, `feed closed: …`).

Under a rule, the selected keeper's own record: its state and the age of its
newest event, then its calls, newest first (`/activity order` turns the order). A run of
the same tool is one row that counts it and says what the calls took
(`Execute ×5 · 2.7s 274ms 1.4s 2.9s 4.7s`, or their sum where that does not
fit); the Keeper Calls surface (`t`) reads each call one by one. `Enter` or
a press on a call opens its facts, input and output; on an earlier turn's
row it opens that keeper's calls surface.

An earlier turn's row states its tokens as parts. When the runtime reports
its cache, the input is split into what the turn processed fresh and what it
read back from the cache: `30 calls · in 159.8k new · 3.56M cached · out
6.6k`. The input count alone (`in 3.72M` for that turn) holds the cache reads
and is mostly them on a cached runtime. A
runtime that reports no cache reads, or counts that do not add up, keeps the
single `in` figure.

The `Changes` tab lists the files this keeper's calls wrote, newest first.

## Surfaces

### Dashboard

The first screen shows workspace health, the number of listed Keepers, two
active Goals, Task flow, quota coverage, and up to two operator attention
items. It leaves individual Keeper rows, Task rows, provider meters, and logs
to their own destinations. The Recent activity pane is open beside this screen
on a terminal wide enough for it.

For a Goal, `actual` comes only from an explicitly recorded measurement bound
to that Goal's current criterion revision. The screen says `not recorded`,
`not observed`, or `unavailable` when it has no valid value.

In **Needs your decision**, individual request rows show their kind, recipient and reason.
Enter opens that exact held-call, approval, question, Goal or task reader;
it never submits a decision.

Use j/k or the arrows to choose, then Enter to open. Esc from a reader opened there returns to
Dashboard with its selection and request window retained.

**Conversations** uses the last explicitly visited conversation saved as
`[tui].last_chat_keeper`, independently of the opening preference. With no available remembered target, choose a
Keeper. An empty, successfully read roster offers creation while any existing
Goal or task decisions remain visible. A conversation opened through Conversations returns to Dashboard with Esc
and keeps its draft through the existing per-Keeper draft store.

Open Work → Goals for the metric,
proof, and activity.

Operations `s` or chat `/music` opens the music workbench; see the
[alphaTex tool README](../tools/alphatex/README.md).

### Work

`t` switches between Goals and Tasks. Goal
details retain their criterion, measurement and linked Task references.
In Goal detail, `j`/`k` scroll
the document and the action row shows the requests available in that phase.

### Usage

Current provider quota windows are grouped by **quota scope**. A scope may be
a provider row or a credential source; its short identifier distinguishes
multiple scopes without displaying a credential path. The provider reports
their utilization and reset time. Catalogue quota blocks are labeled
separately. The 1/7/14 UTC-day plot uses the latest stored provider report for
each day; `·` means no report was stored for that day, and `w` changes the
window. A failed read is labeled unavailable rather than drawn as zero.

Calls draws the tool calls of the same 1/7/14 UTC-day window: one bar each for calls, failed calls and p95,
one column per UTC hour (1d) or UTC day (7d, 14d), and a table of the same
numbers with the newest bucket first. `·` is a bucket in which no call ran; it
has no p95 and is not zero milliseconds. A column is red only when every call in
it failed. The newest column is still open. The heading names the time of the answer the bars were drawn from.

Keeper rows show recorded 24-hour token and cost totals with the number of
turns that reported each value and the number missing it. Transport delivery
is also here. `p` opens Telemetry, retaining the engine, work outcome, and
memory/Gate safety readings (`1`/`2`/`3` select those sections); `p` returns
to quota and Keeper usage. Activity and the server log are reached from
System when a detailed event timeline is needed.

The next refresh rereads the login sources,
so signing in or repairing a login file is visible without restarting MASC.

An account that has not reported since the server started draws no row,
unless the runtime catalogue observed its quota exhausted; then it draws one
`no usage data` row with that tag. A read with no row to draw says
`no usage data`.

A meter is drawn in the exhausted style only when the value reaches the full
value of its own unit (`1.0` for a fraction, `100` for a percent) and the
window gates model calls. A window the server classifies as counting
something a model call does not need (Z.AI `TIME_LIMIT`, OpenRouter's
free-model daily requests) is drawn dim whatever its value. A reset time
that has passed reads `reset time passed · no newer report`; the meter keeps
the last reported value. An account whose runtime rows carry
`quota_exhausted` wears `exhausted (observed)` with the catalogue's own reopen
time, and is listed first. A failed read is one line,
`usage data unavailable: <reason>`. A failed email read adds
`account emails unread: <reason>` after the rows, and email rows this build
cannot read are counted in one note there.

On Usage, `f` searches accounts through the command palette. Choose an account
from current inventory or recorded history; `v` switches Plan/Trend/Keepers/Calls
(`V` goes back) and `w` changes the history window while retaining the exact
quota scope ID. Plan and Trend show that account; `a` restores all accounts.
Keepers usage and Calls remain workspace-wide readings.

### Activity

Every keeper's actions as the runtime event feed delivers them, newest first:
tool calls and their returns, turn boundaries and turn done rows, chat rows
landing. This is the surface for watching ten keepers at once without
opening ten chats.

Marks: `◐` a call
started, `●` a call returned, `✕` a failure, `✧` a boundary inside a turn
(a provider call's start or end, an internal agent run's start), `●` done
(the keeper's turn, or an internal agent run), `▲` something needing
attention. A returned
call shows how long it took when its start is among the events held; a
call that began before the feed opened shows none.

`f` cycles three explicit scopes. `turns` is the default and folds each Keeper
turn to one row while leaving internal agent runs and approvals separate.
`actions` shows the flat calls, returns, turn boundaries, turn done rows, and chat
events. `everything` additionally shows heartbeats, composite/snapshot pushes,
chat stream frames, waiting-queue changes, and telemetry. Its quiet gray rows
carry no mark at all, and are state observations rather than failures;
`composite` specifically means the Keeper composite snapshot changed. `agent start`/`agent done` are internal
agent runs rather than Keeper turn boundaries.

Scrolling down into older rows (`j`) freezes the view: new events count up
in `New above N (g)` on the status row instead of pushing the rows you are
reading. `g` returns to the newest row and clears the count; `G` goes to the
oldest held.

### The composer and /task

The input row at the bottom of every surface sends text to the keeper it
names. A line that starts with `/` is a command for the TUI instead:

- `/task <title>` — followed by any further lines as the body — creates a
  task over the server's `masc_add_task` tool and then messages the keeper
  the operator's own words with the new id in front: `[task-512] <title>`.
  The keeper claims that exact task. Only a failure before send restores the command
  automatically, and only while its original input remains untouched.
- `/task-recover` — restores the latest retained failed or unconfirmed Task
  command for this Keeper and matching workspace. It only restores input;
  it does not create or send a Task. A server error or missing reply does not
  prove that creation failed: use `/task-inspect` before repeating the command.
  Retained commands live in this TUI session; they are not restart recovery.
- `/task-inspect` — opens this session's completed Task creation requests,
  including successful creations, for this Keeper and the confirmed original
  workspace. Successful requests remain available for reading, while
  `/task-recover` continues to select only failed or unconfirmed commands.
  To keep an existing chat draft, leave composer focus with Esc, open the `:`
  command palette and search `task-inspect` or the original title. Choosing an
  `inspect Task creation` entry opens that exact retained request without
  consuming or restoring the draft.
  `[` selects an older request, `]` a newer one,
  and `r` reads the displayed source again. The original title, body and
  transport outcome remain visible beside the lookup. “Not observed” does not prove that creation
  failed; multiple records remain ambiguous. After a single ready creation
  fact, `o` reads that exact original Task inside the inspector, independently
  of the global Task list. It distinguishes live backlog, archive, not observed,
  retained deletion evidence and read failure. Full decoded Task fields remain
  scrollable; `r` refreshes that Task and `b` returns to the creation facts.
  `h` reads a fresh stored history prefix; `H` reads its known older page.
  `v` reads the next verification submission observed in ready Task/history
  data; evidence `r` stays pinned to that exact Task and submission.
  `/` searches the displayed original document; typing and paste stay in that
  query. Enter keeps it for `n`/`N` to move between matching rows. While editing,
  source keys such as `r`, `h` and `v` are query text, and Esc cancels the query
  while keeping the inspector open. Outside query editing, Esc closes it.

- `/diff` — opens the working-tree Git changes directly in chat. Pressing
  `Enter`, `d`, or `Right` opens the file's Git diff inline with syntax
  highlighting and line numbers; `j`/`k` scrolls the diff, `v` opens the
  file in the Code surface, and `Esc` or `Left` returns back to the files list,
  or back to chat.
- `/changes` — switches to the Changes surface showing the active keeper's
  recent file modifications, with `Esc` returning straight back to chat.
- Any other `/word` is reported as unknown and sent nowhere. Text that
  merely contains a slash later in the line is a message.

A command's answer (the command list, a queue snapshot, a preset listing) is
a row in the chat pane. A step of the operator's that did not work - a
command missing its argument, `Ctrl-V` on a clipboard with no image, an image
that would not open - is not part of the conversation: it reads on the
footer for twelve seconds and stays in the event log.

### Keepers

Every keeper under `.masc/keepers/`. The default order is priority; `o` cycles
the others.

Column meanings and marks are in [TUI-KEYS](guides/TUI-KEYS.md) (Keeper columns,
Keeper marks). A Keeper whose tool gate is YOLO draws its name in red. Names,
last-turn times and tasks stay readable while the runtime is down.

`Enter` opens the Story window under the list for the Keeper the cursor is on.
The window takes rows from the list, so the list keeps scrolling to the cursor
in what is left, and it follows the cursor as `j`/`k` move. It has three pages
named on its title row: `story`, `s schedules` and `m memory`.

- `story` tells the Keeper as `◂ past`, `● now` and `▹ next`. Past holds the
  failing-for and turn-pulse cells, the feed, the failure sentence and the
  attempt chain. Now holds the activity word, the `DETAIL` text, `Mode S`,
  `AGE` and the lifecycle. Next holds the schedule cell, the next dispatch path
  and the memory lag. Except the feed, they are the cells and sentences the
  list rows draw.
  The feed lists the Keeper's newest turns, its newest two wakes and the
  Librarian's last digest, oldest first, one line each with how long ago it
  happened, so the newest is the last event of the feed. A turn line gives the
  stop reason the receipt recorded, as written, or `turn no stop reason`. A wake
  line gives its outcome, the schedule that woke the Keeper and, for a failed
  wake, the error the schedule recorded.
  A source the window has not read, cannot read, has cut, is reading again or
  whose read failed does not vanish from the feed: a line of its own after the
  events says so, one line per source, for example `turns reading`,
  `wakes from the first page only` or `wakes (schedule read failed)`.
- `s schedules` is the first page of the Keeper's own schedules, the page the
  Automation tab (`J`) draws first, led by the same `◷` cell the list draws and
  the counts of what the store holds. The
  Automation tab has the full table and the other pages.
- `m memory` shows the Keeper's memory-health row: state, update age, the fact
  age ladder, the Librarian's lag and last digest, the gap and the stale
  events.

While the window is open it takes `Tab` (next page), `s`, `m`, `Enter`, `Esc`
and `Right`, and `S` and `M` as it takes `s` and `m`; every other key reaches the
list. `Enter` closes the window on the story page and returns to it from the
other pages, `Esc` closes it, and `Right` closes it and opens the detail. A closed
window takes `Enter` and nothing else, so `s` still shuts a Keeper down and `m`
still opens the chat. Leaving the list closes the
window.

Execution facts are not on the list. Open the selected Keeper's detail
(`right`); its Info tab shows `Lifecycle`, `Turn`, `Idle`,
`Last outcome` and `Last runtime` (the runtime that produced the last
outcome, which after a failover is not the runtime the Keeper is assigned). When a refresh fails after an earlier
reading, Info keeps that reading and puts `stale · refresh failed: <reason>`
above it; when there was no earlier reading it says `unavailable` with the
reason instead of guessing zeros.

`g` toggles the selected Keeper's tool gate. The footer names the action that
will happen next: `g yolo` from the approval policy and `g auto` while YOLO is
active, so the safe return path is visible.

What YOLO covers is narrower than the name. It skips the approval hook that
asks over the open chat stream, and nothing else. External effects that go to
the Gate — writing to a service the Keeper is attached to, a sandbox command,
a durable memory write — are still decided by the workspace Gate mode and that
Keeper's own override, whatever this toggle says. The per-Keeper `yolo` / `auto`
setting is persisted under `.masc/gate/` across server restarts.

The `v` view and `o` order are stored in `tui-keepers.toml` in the resolved
config directory and restored on the next start; a failed or unconfirmed save
is reported.

`K` opens a read-only relationship view for the selected Keeper: each arrow
comes from the recorded Keeper sender of a request queued for that recipient.
On a settled page, `[` and `]` choose a verified sender and Enter opens that
Keeper's Info view. Use `<` and `>` to read earlier or later server pages,
`r` to refresh the current page or retry a failed one, and `R` to start again
from the first page. The cursor does not identify a Keeper's storage
generation; restart if that Keeper was deleted and recreated. Esc closes the
view.

The attention group holds held calls, questions and confirmations. A Keeper
whose health is failing is in the failing group unless it is waiting on a
person, and it stays there after it starts a new turn. A Keeper whose open
turn has a failed attempt is in the failing group too, unless it is waiting
on a person, paused or offline.

### Lanes

Lanes is the common operator inventory for exact-output services, Browser
backends, shared MSX/DOS machines and package installations. Runtime candidate
orders remain a separate Runtime tab. Keeper lifecycle and turn-cycle facts
remain on Keepers.

Invalid TOML and workers with unconfirmed cleanup stay visible.
A saved declaration and an observed worker have separate readings. Missing data
from a partial read does not mean a Lane was removed or disabled.

A mouse press selects the row actually drawn, and pressing the selected row
opens it. Declaration documents open for inspection: `E` edits and `s` saves explicitly.
Existing drafts are retained.

`o` or `A`, `/addons`, and
`go Features & plugins / Plugins` keep the full package management surface available. See the [Lane Add-on guide](guides/tui-lane-addons.md).

The
[inventory contract](guides/lane-inventory.md) names each observation precisely.

On Lanes, select an exact-output lane and press `s` to edit its model order. Arrow keys or
`j/k` select a candidate. Press `r` to replace it at the same position;
type a configured model and reasoning effort such as `luna medium`, select
with arrows and press Enter. The choices show the declared reasoning effort,
account provider ID and context. Unset reasoning is shown as `default`.
Replacing a candidate selects another configured runtime; it does not change
the shared model's settings in other lanes.

These changes save immediately. The result
shows file durability separately from application: exact lanes may be applied,
unchanged with a reason, or unavailable until restart. When the prior exact
configuration is kept, correct the reported configuration problem before
restarting. The notice also names pending Keeper settings and lock warnings.
Keeper values overridden by environment
settings remain visible as warnings even when no restart is required.

Standalone Lane model settings use the same form as System → Models. In the
Lane's `s` model-order editor, `Enter` or `d` opens the selected account/model's
context, output and sampling fields. Runtime detail's `e` and the All runtimes
roster's `e` open the same form.
`m` in System → Models opens the source reading.

### Clients

Everyone attached to this workspace in one reading: directory agents,
state-backed sessions, and runtime fibers. The Keepers roster answers which
Keepers exist; this answers who is here now, which includes identities no
other surface lists, such as a non-keeper MCP client. Open it with `c` on System / Runtime; `p` or `Esc` returns to Features & plugins.

The status
is the closed agent enum (`active`, `busy`, `listening`, `inactive`);
inactive rows stay in the roster, receded, because "who left" is part of
the reading. This is a registry view, not a socket list - a leftover
process holding a connection is still an `lsof` question.

### Exact-output Lane detail

To open retained observations without a current configuration row or installed
Addon, press `:` and choose `go Workspace Curator history` (or search by the
logical lane ID, such as `workspace_curator_exact`). Each history destination
uses the original lane identity; Enter on a run opens its retained detail.

A client with no output-schema channel fits no exact lane, so the picker lists
it below every runtime that can land, its row led by `no output schema`.

Each payload is bounded at 64 KiB; a larger retained
value says its original byte count instead of ending in an unexplained `~`.

`Verifier` joins two durable review registries: task completion-authority
reviews and Goal proof reviews. Its run list names `task <id>` or `goal <id>`
in the subject column and keeps the producer verdict (`approved`, `rejected`,
`committed`, `deferred`, or the exact failure) as the status, so approval and
rejection do not require opening every row. Detail names the review kind and
shows the request followed by the retained result, reason, evaluator runtime,
and tool observations including input, disposition, output excerpt, duration,
and truncation state.

### Keeper detail

Right from the Keeper list.

The Channels tab lists every transport and its channel bindings. A channel
reads `name (id)` when the connector's name directory knows it, and
`id (name not reported)` when it does not.

A browser consent started on the Services tab keeps checking its Keeper even
on another surface. A callback the server admitted just before `expires_at`
can still be publishing credentials after the URL is gone, so wait for its
result instead of starting a second login.

The Items tab is one `]` after Info. The portrait tries the selected accessory over the
Keeper's observed outfit; Space compares it with the current outfit. The wallet
shows Candle and the number of purchased accessories. The selected item shows
ownership, price, affordability or the missing Candle amount, even in a narrow
pane.

`a` opens an editable chat draft asking this Keeper to buy and equip the selected
item, or only equip it if already owned. The purchase request caps the price at
the observed milli-Candle amount, including zero for free items. Enter sends the
draft through normal chat. An existing text or attachment draft is preserved;
send or save it before preparing the Item request again. Buying and equipping
remain Keeper-owned tool actions, and the reply reports their result. Return to
Items to read the resulting ownership and outfit.

After `U` `U` on the Channels tab, the TUI session block gets one line per
binding -- removed, kept (now bound to
another Keeper), not found (with the server's words), or FAILED with the
server's reason, failures last -- and the footer shows the count of each and
names the channels that failed. A transport whose binding list the server
could not read is named in the prompt as not included.

Pausing (`p`) or shutting down (`s`) a Keeper that still holds channel
bindings offers to remove them too. A paused Keeper keeps its channels routed
to itself and answers on them as soon as it runs again. Once the pause or
shutdown is accepted, the footer reads `y: also unbind <keeper>'s N channels,
or any other key to keep them -- <channels>`. `y` sends the same conditional
unbinds as `U` `U` on the Channels tab; any other key leaves the bindings.

The Terminal tab is the last tab, one `[` back from Info. It shows the
Keeper's Execute output the way a terminal does, oldest row first and the
newest at the bottom. A command line starts with `$ ` (`> ` on its later
lines), then comes what it printed, with stderr in the warning colour and a
`· exit 0` row when it ends. A signal, a rejection, or an unknown result gets
its own row there. The command line is the server's summary of the
command, not a quoted shell line to paste.

While the tab is open the TUI holds a connection to the Keeper's Execute output
stream and keeps the newest 500 rows. The row under the output says `following`, how many commands are
active (`closed` when none is and the last one ended, `state not reported` when none
is active and the server has not recorded an end), and when the server last
said anything on the connection. When commands
overlap their rows interleave, and each row then starts with its stream number
as `[3] `, or `[?] ` for a row the server did not attribute to a stream.

When a connection ends the last rows stay, marked stale with the reason. The
TUI retries a lost connection or unreadable frame after two seconds, increasing
the wait up to 30 seconds if failures continue.

Other HTTP refusals, including a successful HTTP status without the required
workspace receipt, stop the stream and show the reason. After correcting the
underlying problem, press `[` then `]` to leave and reopen Terminal and retry.
The last rows remain available while the stream is stopped.

`k`, `PgUp`, `Home`, or the mouse wheel stops following and holds the screen as
it was, so output that arrives meanwhile does not move the rows you are
reading. The row under the output then says `paused`, how many newer rows have
arrived, and `End:follow`.

Scrolling down to the bottom follows again too. Leaving the tab, or choosing
another Keeper, drops the hold: the next reading opens at the bottom. The rows come from the server process's memory (the newest 5,000 events
per Keeper), so a Keeper that has run nothing since the last server restart
shows `No Execute output observed in this server process.`

### Keeper logs

`l` from the roster, `L` from detail. The newest 200 physical rows from the keeper's dated metrics
store.

Malformed JSON, current-schema decode failures, and storage failures are shown
rather than skipped.

### Keeper calls

In a Keeper chat, `/calls` opens the original calls captured from that
conversation. Use `j`/`k` or the arrow keys to choose by the original input,
target and execution ID, then Enter to read the recorded input and output in
full. The open action beside a folded long result opens that exact execution
directly. Execute results also expose their printed output with its original
line breaks. If no original execution ID was recorded, the reader says so.

Inside a result, `j`/`k`, PageUp/PageDown and Home/End scroll the whole record.
`/` searches the captured document; Enter keeps the query for `n`/`N` to move
between matching rows. Matching rows carry `*` in their existing left margin;
the current search landing carries `>` and a reverse-video band, including with
`NO_COLOR`. Esc while typing cancels
the query and keeps the reader open.
`r` rereads the same execution and keeps the last result, read position and any
known read failure while the new read is pending. Esc returns to the original call
selection; another Esc returns to the chat with its draft and conversation
position intact. If the turn has not
published its trace, the trace was not retained, or reading fails, the reader
keeps the preview and explains the source state.

`t` from the roster or from detail. Each call shows its time, result mark, duration and turn, then its exact tool, input and output. The header carries the server's own
freshness verdict (`ok · latest 12s ago`), so a stale page does not read
as a quiet keeper, and a row naming another keeper is counted and not
drawn rather than attributed by file position.

### Keeper message

`c` (or `m`, except while the roster's Story window is open) from the roster or
detail opens a chat with that Keeper; Enter sends. The send
runs in the background, so refresh and navigation stay responsive while the
turn runs. `Esc` returns to the roster when chat opened there, and to detail
when chat opened from detail.

The header joins the selected Keeper's published status with its typed runtime
phase and producer-owned canonical `runtime_id`, using the same roster reading
as the Keepers table. It also always names the chat approval stance
(`AUTO` or `YOLO`) and the effective durable Gate mode in the words the [w]
chooser uses (`gate: manual`, `gate: Auto Judge`, or `gate: allow-all`). A
Keeper that inherits `workspace` shows the observed workspace mode rather than
the word `workspace`; an unread Gate observation reads `gate: not loaded`.
While no
turn is starting or running, `Ctrl-G` selects the next readable Keeper and
wraps at the end of the roster. Each Keeper keeps its own draft. The shortcut is withdrawn while a turn is in flight or the
roster cannot be read.

Chat opens in a conversation layout: a small `›` marks your message, `✦`
marks the Keeper, `✧` marks the pane's note about a turn, and `◀` marks
another sender. Other senders keep their name
and origin above their message. Tool calls keep
their own name and result mark without a second TOOLS label.

`Ctrl-F` cycles conversation → inline metadata → full origin headings →
conversation. Inline metadata includes the minute clock, aligned speaker labels
and turn rails.
Full headings give origins a row of their own.
The header labels only expanded modes (`metadata:inline`, `metadata:full`).

The input area shows progress for the current conversation. The default progress row shows the current activity without generated
progress timers (request age, call age and model silence); those timers,
runtime identity and cumulative tool details are available in the metadata views.

Inputs waiting to enter a turn appear under `대기 입력` with the local `›` mark.
The label beside each original input distinguishes unsent (`전송 대기`), sending
(`전송 중`), accepted and waiting to be processed (`처리 대기`), and unconfirmed
delivery (`전송 확인 중`). Acceptance alone does not mean the Keeper has processed
it. Rejection details appear separately as an error.

Expanded diagnostics (`Ctrl-D` to full) follow the whole message, and a waiting
input names its request there too.

`/find <text>` searches the conversation that is drawn, including replies and
activity retained in live or settled journals. `/find` repeats toward older
matches using record identity, so incoming messages and history backfill do
not restart the search. Hidden reasoning is excluded.

Search lands on the physical body row containing the match, including inside
a long or wrapped answer. It searches rendered words, so `foo bar` also finds
`foo **bar**`. A line break in the source is an optional boundary: words on
either side of it match with or without a space in the query. Width wrapping
is not: it changes where rows break, not the searched text, so a space the
author wrote still has to be in the query (`foobar` does not find `foo bar`
however the terminal wraps it).

While reading back, the pane pins projected history or journal origins and
their physical body-row positions. Incoming input, broadcasts, streamed text,
and settled journals therefore do not pull the view toward the tail.
Returning to the bottom releases the pin and resumes following output.

The pane opens on the keeper's durable transcript. A turn the keeper ran on
its own is drawn as what it did. Reasoning starts folded with a `THINKING`
label; tool calls start as a compact activity row labelled `TOOLS`.
`Ctrl-R` cycles reasoning through folded, full, and hidden; `Ctrl-D` cycles
tool details through compact, results, and full, so
full arguments and unfolded Gate history are two presses from compact. Results
keeps one row per call and adds what the call answered: a short preview of the
recorded output, `not seen` when the transcript never observed a return, and
`no call-log row` when the durable log has no entry for the turn. In compact
mode, successful Gate lifecycle steps for the same Keeper and approval are
summarized at the last step, even when conversation separates them. The summary
names the step count; Full restores every original step. `/thinking` and
`/tools` expose the same choices by name (`/tools results` jumps straight to
the middle stop). `--reasoning` and `--tool-view` can
override the initial modes (`--tool-view results` opens on the concise
results).

A turn this TUI did not open -- one running when the TUI started, or one
another surface opened -- is drawn from its journal while it runs.
A turn whose stream the TUI opened and lost is followed the same way.

Memory journal rows start hidden. `Ctrl-N` or `/memory` cycles hidden → summary
→ full → hidden. The header names the expanded modes as `journal:summary` and
`journal:full`; the default needs no badge. The help sheet lists the journal and metadata shortcuts.

A failed Librarian pass is not a row in summary mode. While the passes after
the last commit keep failing, the header's second row names the run once, in
every journal mode: `Librarian failing ×5 since 14:02:13 ·
exact_execution_failure` - how many in a row, when the first was recorded,
and the server's word for how the newest failed. The next commit ends it.
`journal:full` still draws every failed pass as a row of its own.

A turn's Skill invocations are one block, like its tool calls. At rest it
draws one row per skill, in the order each was first triggered, with how many
times: `msx-observe ×7`. A trigger that failed, or whose evidence the pane
could not read, adds that state's words (`prior-art ×2 · 실패 1`). Cycle `Ctrl-D`
to full to open every invocation: how far it got (an instruction skill is
`읽음`, a
composition `실행됨`), the tool calls the server attributes to it, and its
proof coordinates. An `Execute`
call whose result reads as the output schema its descriptor declares draws
`status` (`exit 0 · 808 ms`, `signal 9 · 30012 ms · timed out at 30 s`), the
command's `output`, and any `stderr`. Output too large to ride inline is named
by the artifact that holds it (`artifact sha256:9f3a12c4d5e6… · 48213 bytes`).
The Keeper Calls view
(`t`) keeps the stored result whole. A held tool call
uses decision vocabulary independently of execution: `approval approved`,
`approval denied`, `approval timed out`, or `approval displaced`. Its later
tool row still reports whether execution returned or failed.

Full tool detail also keeps a Keeper's recorded file change inside the turn
that made it. The pane does not fetch file-change bodies in compact or results
mode; cycle `Ctrl-D` twice from compact to open Full and perform that lazy read.
The inline block names
the resolved file address, added/removed row counts, producer-recorded old/new
line ranges, and a bounded `diff` preview. At most three changes are expanded
per tool block and each preview holds at most twelve rows; an omission names
its exact count and points to Changes for the complete view.

#### Prompt presets

The System `presets` pane (reached with `p`) lists each preset by name with its
counts (prompt overrides, Keepers with instructions, runtime assignments,
exact-output lanes). The detail below shows its save time and description, a
comparison with current settings, this session's last restore report, then the
saved contents and the Keepers it holds. A directory whose manifest does not
read is listed with `✕` under Read errors.

The chat does the same. `/preset` lists the prompt presets the server holds
under `.masc/presets`.
`/preset save <name> [description]` snapshots the live state under that name.
`/preset restore <name>` saves the live state first as `_autosave`, replacing
the one the previous restore left, then applies the preset surface by surface
and reports each one: prompt overrides take effect at once, keeper
instructions at each keeper's next up, and runtime routing through a
runtime.toml commit. `/preset restore _autosave` undoes the latest restore's
prompt overrides and runtime assignments; a keeper that had no instructions,
or a lane that restore added, stays as it left them. Every skipped key
is listed with its reason, and a restore that skipped anything or whose
commit failed is shown as an error. Unpublished lanes
require a restart; a retained stale registry instead needs its configuration
repaired before a restart can publish it. A durability warning means the change
is already applied, not that the restore should be repeated. Inspect current
settings and `_autosave` first: repeating restore replaces the undo snapshot.
An unreadable response also does not prove that nothing changed.
`/preset delete <name>` removes that
preset, including one listed with `✕` because it does not load; typing the
name is the confirmation. A directory whose name is not a valid preset name
is refused.
The answers land in the chat pane of the keeper selected when the command was
typed.

#### Context inspector

`/context` or `Ctrl-X` opens four tabs for the selected Keeper: `1:stack` summarizes
the recorded context composition, `2:request` lists the exact canonical input
items retained for the provider request, `3:proof` explains each recorded
component's source and evidence strength, and `4:response` shows the turn's reply. At 110 columns and wider, the request
and proof tabs draw two columns with their headers pinned above independent
windows: `j`/`k` moves the left list while the selected item's text or
provenance stays put at the top of the right column, `h`/`l` moves which pane
hears `j`/`k` (the caret on the pinned header names it), and with the right
pane focused `j`/`k` scrolls the item itself. Narrow terminals keep the same
facts in one column; `Enter` opens exact text at full width.

`[` and `]` step back and forward through the page's turns -- the caret on
a RECENT TURNS row names the one on screen -- and every tab re-reads the
exact provider input for the row they name; a turn that retained no
snapshot says so on the request tab rather than showing another turn's.

On the request tab, `/` searches the item labels the way the keeper
roster searches names: typing jumps to the first match, `n`/`N` cycle,
`Enter` settles, `Esc` clears. The query draws beside the tab row.

Evidence badges are claims, not decoration. `VERIFIED` means exact text was
checked against the producer digest and byte count. `SERIALIZED` means an exact
same-turn pre-dispatch request snapshot exists but no item-level key joins that
component to one retained item; it does not claim transport began or the
provider accepted anything. `DIGEST ONLY` means a producer prompt-block digest
is retained without same-turn exact text. `BYTES ONLY` means only the component
byte count is available.

#### Reading chat loading errors

If saved history, older messages, or the memory journal cannot be loaded, a
short warning above the input points to `/errors`. Run it in the open Keeper
chat to put the current full details in the local conversation log, where
lines wrap and you can scroll back through them. Hidden memory-journal errors
are included.

#### Copying a reply

In a Keeper chat, type `/copy` and press Enter to send that Keeper's latest
completed reply to the terminal clipboard through OSC 52. The chat notice names the
Keeper and character and byte counts, and says terminal clipboard support is unconfirmed:
OSC 52 has no success response. If the history cannot be read or has no reply,
`/copy` reports the failure instead of copying a displayed line.

#### Pasting

A paste while the composer row is idle takes focus for it, so pasted text
always lands somewhere visible and addressed to the keeper the row named. With
no keeper to send to, the paste is refused out loud in the TUI session block
rather than dropped.

A paste longer than 50 lines, or larger than 8 KiB, is not put into the draft.
One line stands in its place:

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
instead and say so in the TUI session block.

`Ctrl-U` drops both.

A paste over 1 MiB keeps the first 1 MiB. The rest is read - the end marker
has to be consumed, or the tail of the paste arrives as keystrokes - and
counted, and the TUI session block says how many bytes are not in the draft.

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

A path that cannot be read, or a file that is empty, is refused on the
footer.

In Keeper chat, `Ctrl-O` previews the newest image or closed `mermaid` fence.
`/images` lists the available images and diagrams. `/images N` opens an item,
counting newest first. Generated audio and Standard
MIDI files (`audio/midi` or `audio/x-midi`) are available through `/listen`.
Structured Mermaid outputs use the same actions. Install Pele with
`scripts/install-pele.sh` (Node.js 22+ and pnpm). The companion runs offline and renders charts, mindmaps, class
diagrams and other Mermaid types as terminal images. Any key returns.
Image-capable terminal support is required, as for other `Ctrl-O` previews.
See the [renderer installation and request contract](../tools/pele/README.md).

#### Keeper Job notifications

Chat keeps the selected Keeper's scheduled Job status above the composer.
Press **F9** to expand or fold the list.

Keeper Automation remains
the place to inspect the full schedule page.

#### Lines typed during a turn

Enter during a running turn is the explicit **queue next** action — the footer
labels it `Enter:send update`. It holds the line for a later turn rather than
pretending the running model saw it.

`/steer <message>` is a distinct action. It asks the current turn to stop and puts the replacement ahead of that
Keeper's other waiting lines. The replacement is dispatched only after the
current operation reaches a terminal state; an interrupt acknowledgement is
not misreported as completion. A second pending steer for the same Keeper is
refused instead of silently replacing the first.

If the stream disappears without terminal evidence, the row changes to
`reconciling` and the TUI re-subscribes with the same idempotent operation ID.
The Keeper remains occupied and every waiting line stays held until the
server emits a verified terminal receipt.

`Ctrl-T` or `/queue` opens the selected Keeper's queue in a separate panel,
leaving the chat and draft in place. Use Up/Down to select an item, Enter to
read its identity and available detail (including queued message text and
attachment information), Page Up/Down to browse
the list, `r` to refresh, `?` for help, and Esc to return. A selected local message can be
moved first or last among that Keeper's unsent messages with `n` or `l`;
existing edit, admission and retained-input holds still apply.
The selection mark and
some item text must fit; if the terminal is too narrow, enlarge it before
opening detail or changing the queue.

For an accepted server message, `n` requests the next position and `l` moves it
to the end. A
next request does not interrupt the current turn. For a pending event, `n` and
`l` set immediate and low urgency respectively; urgency is not an exact queue
position.
Refresh before acting when in doubt.

When a command-only queue panel is visible over chat, an individual two-set
Hangul key can also activate its corresponding Latin shortcut.

The panel reads the selected Keeper's server inventory. Its counts separate
pending inputs, running work, future schedules, due schedules and unavailable
sources. An aggregated chat row counts every queued request.

A failed roster read blocks sending. When `.masc/keepers/` cannot be read
reliably, a stale entry may still name the target, so membership alone does not
authorize an external effect - the surface renders
`Keeper roster is unavailable` and the footer reads
`Enter:disabled (roster unavailable)`.

### Approvals

Operator approvals scoped to the acting actor.

`Enter` opens the selected request as a wrapped, scrollable field list before
the operator decides it. A blocked Auto Judge request puts `state`, the exact
producer `reason`, and the available `next` action before its approval ID,
execution location, and input. `R` retries only when the
detail says retry is offered, while `y` and `n` remain available for a human
decision.

### Board

Posts with their vote and comment counts.

`s` cycles five server-owned rankings, with the active formula printed above
the table: `hot` is net votes descending with newer posts breaking ties;
`trending` is net votes divided by the square root of age in hours; `recent`
is newest creation first; `updated` is latest change first; and `discussed` is
reply count descending with newer posts breaking ties. `f` cycles the hearth census shown on the next line, so
ranking and topic narrowing remain separate axes.

`w` on the list opens a new-post draft. The draft follows the commit-message
convention: the first line is the title, the rest is the body. `Enter` makes
a new line, and sending is armed rather than pressed - `esc` offers
`s:send d:discard`, so no stray key publishes. A rejected post
keeps the draft and shows the server's message.

`v` votes the row under the cursor up, `V` votes it down - the shift key is
the direction. Like every irreversible action here, the first press arms and
the same press again sends. In a post, `c` replies: the same compose pane
opens with the post as its target, the whole draft is the comment, and
sending returns to the post with the reply visible.

A ` ```alphatex ` fenced block in a post or comment body is drawn as a guitar
tablature box instead of plain code - what renders, what the fallback box
means, and how to turn it off are in the
[alphaTex tab guide](guides/alphatex-tab.md).

A post's attachments are listed at the end of its body under `ATTACHMENTS`,
each with a `[N]` number. On the read pane, pressing the number opens that
attachment: audio plays locally (afplay or the next player on the chain),
MIDI plays through fluidsynth (set `[tui] midi_soundfont` in runtime.toml;
without it the file is handed to the local app with a note saying why), and
file and score attachments with stored blob references open a captured reader.
Use `u` for source, `m` for Markdown or `h` for inert HTML, `y` to request an
original-text copy, and `s` to save original bytes. `/` searches this reading;
Enter keeps the query for `n`/`N`, and Esc while typing cancels it. A MIDI that parses reports what it is on
the status line (tracks, BPM, time signature, length). What each key did,
or why it could not, stays on the pane's bottom line until the next post
opens.

A closed post's resolution is part of its scrollable body: the closer, supplied
close time, complete summary and recorded successor remain readable at narrow
widths. `S` opens the successor named by that post's metadata, including posts
outside the loaded list. Esc returns to the original post.

### Work / Goals

`Goals` is the goal lifecycle, judged against the
goal verification ledger. `Task Review` and `Task Verdicts` are the two
halves of the Task protocol: what is waiting for a ruling, and what was
ruled.

Each side carries its own count on the strip: `Goals·2` is goals with the
completion judge, `Task Review·7` is tasks waiting for a completion verdict.

`f` cycles `all`, `active`, `completed`, and `dropped`; active means every
phase that is neither Completed nor Dropped: Executing, Verifying,
Awaiting confirmation, Paused and Blocked. `s` cycles `phase/P1-P5` (Executing, Verifying,
Completed, Dropped, then priority), `updated` (most recently changed first),
and `due` (earliest due date first, undated last).

An Executing or Verifying goal whose due date has passed says `past due` after
its phase, in the row, the preview and the detail's Due field. A goal falls due
at 23:59:59 UTC of its day. One whose due date cannot be read says
`unreadable due date` rather than passing for a goal with no date.

Goal detail's `RELATED ACTIVITY` block is not a complete Task history. It shows
the latest state per linked Task and Keeper, pending approvals, and Goal phase
events.

In Work's task list (`t`), `x` on an open Task detail cancels it: `$EDITOR`
takes the required reason, and the TUI's authenticated operator credential is
needed.
Completed Tasks cannot be cancelled. A missing or insufficient credential is
refused. If the response is lost, the TUI reports the result as unconfirmed and
refreshes the captured workspace; it does not claim the cancellation failed.

#### Task Review

Task Review lists Tasks submitted for completion verification. The normal
reviewer is the automatic completion authority; an operator can also decide a
submission. A queue entry does not by itself mean human approval is required.

The Task flow is `Todo → Claimed → InProgress → AwaitingVerification → Done`.
A rejection returns the Task to `InProgress` for repair and resubmission.

The list separates submitted evidence count from required evidence count. The automatic-review column shows
its last observed attempt: unobserved, running, stopped, or a recorded verdict.
Open a
stopped row to read the actual failure reason; this reader does not infer or
schedule retries from error text.

Press Enter to read a submission. Its title and review reason precede one
selected evidence item.
Completion conditions and required evidence remain available below the body.
Notes, text files, collaboration snapshots and images are identified separately.
Board snapshots show the saved title, author, body and comments as readable
text; exporting preserves the original JSON snapshot.

`o` downloads the selected retained item and asks a local application to open
it; `s` saves a private local copy without opening it. The resulting local path
stays with that evidence item in the detail, including if the viewer cannot
open. Copies keep their original basename inside a unique private directory in
the local temporary directory and never replace existing files. A file reference such as `artifact:reports/a.pdf`
names a producer-workspace source, not a file on the operator's machine.

`a` on the row under the cursor arms an operator approval and the same key
again sends it. `x` rejects with a required reason in `$EDITOR`.

### Schedules

The scheduled-automation list: every wake the runtime has queued, active rows
first by due time. This is the surface that answers "why is this keeper about
to wake up". Open it through the `go Schedules` palette entry. The selected
Keeper also exposes its automation in the Automation detail tab.
Use `<` and `>` on the list, or on a Keeper's Automation tab, to read the
previous or next server page.

WAKE is what the dispatch did and DELIVERY is what the reaction ledger made of
it; they are two facts, and a wake the queue cancelled forty seconds later
still reads `succeeded` under the first.

A store that could not be read is
`data unreliable` with the failing call, not an empty list - "the ledger is
unreadable" and "nothing is scheduled" are different facts.

`x` cancels the row under the cursor. Like every irreversible action here it
is armed: the first press names the schedule, the same press again sends it,
and the cursor moving between presses re-arms for the new row. The payload target column names who the
wake reaches (a keeper, for keeper wakes); rows without one fall back to the
payload summary.

`n` opens a JSON creation form in `$EDITOR`; `e` opens the selected row's
exact editable definition, including its due time, recurrence, expiry, and
stable schedule id. A Keeper wake's form also carries its full message, its
title, and its urgency (a receipt delivery carries `delivery` in its place). A row whose payload kind this build does not name, or whose
kind the server did not send, opens no editor; the footer says why. Exiting
the editor with zero sends the form, while a non-zero exit changes nothing.
The form keeps example fields
for interval, daily, and cron recurrence in place; `recurrence_kind` chooses
which set the server reads. Modification is one atomic
store transition: only `scheduled` or `due` rows can be replaced.

Right or `Enter` opens the selected schedule. The detail includes schedule and instance
identity, dispatch state, requesting actors, timestamps, recurrence, payload
kind/tool/digest/summary, the pretty full payload JSON, last wake, and
queue/reaction evidence. Keeper wakes also show the durable Keeper,
stimulus/occurrence ids, every recorded step timestamp, and the projection's
exact failure or quarantine reason. This receipt proves wake delivery and
whether a turn started; it does not causally attribute later tool calls or a
work result to the schedule. The detail says so explicitly and points to
Keeper Calls or Activity for execution evidence after the recorded turn start. Left or `Esc` returns
to the list; `j`/`k` scroll by a row and `PgUp`/`PgDn` by a page.

### Fusion

The retained Fusion run registry is the list. Open the list with the `go Keepers / Fusion` palette entry;
Enter on a run in a Keeper's Runs tab opens that run's detail here. After following a link, `Esc` returns directly to its origin. Otherwise
it closes detail to the run list, then returns to the Dashboard. While a run is active, `STATE`
shows the exact process-local stage: `accepted`, `panel(N)`, `judge(A/F)`,
`computed(A/F)`, or `recording(A/F)`.

`a` starts a run from the list. `keeper`, `preset`, `topology` and `web_tools` are
Left/Right choices, `prompt` is typed, `Tab` walks the fields, `Ctrl-S` opens
the review and `Enter` there starts the run. `Esc` cancels.
A refusal — a preset that cannot run the chosen topology, for instance —
returns the server's own sentence above the form with the values intact; the
form does not restate it. A request that goes unanswered says the run may
have started anyway, because it may have.

The header repeats the current
stage and its panel counts. `recorded` puts the judge result, resolved answer,
and reason alongside the original question and Board link, followed by every
panel answer or failure in server order.

`TOOL EXECUTIONS` is an execution ledger, not a copy of the `web_tools`
configuration flag. `complete` with no rows means the instrumented
actors made no calls. `partial` names dropped rows and actors that
cannot publish this evidence; an official-client panel is shown as
`official_client_uninstrumented` instead of being misreported as “used no
tools.”

`SEAT ROUTES` is the walk each seat took through its candidates, from the
`seat_routes` array the sink writes. One line per seat names the route it was
given and the runtime that answered — `panel/first · route panel-lane →
answered by glm-4.6` — with every candidate that failed before that one
indented under it as `<runtime>: <code> <detail>`. A seat no candidate
answered says so. Seats are spelled as the tool ledger spells its actors:
`panel/<panelist>` and `judge/<role>/<identity>`.

### Memory

Stored memory sizes show as estimated tokens (≈) by default; `u` switches
between tokens and bytes (B/KiB/MiB). With a Keeper selected, the stored size
is followed by `avg / max / min / last` of its whole request input over its 50
most recent recorded turns, using each turn's last request observation. When
the last turn reported nothing, `last` reads `unreported`. `/context` shows the
same turn's composition.

The table shows each Keeper's Memory OS health. The ordinary current snapshot
and the source-bound snapshot have separate columns; each row carries both
stores' revision, facts, size and source invalidation count, the latest
ordinary change (+added/-removed) and the state. `STARVING` is a Keeper whose
Librarian runs failed and that has neither snapshot. `source-only` has a
source-bound snapshot but no ordinary one. `no-current` is the quiet state
before the first ordinary snapshot, and `degraded` has an ordinary snapshot
while Librarian updates are failing. `read-error` means either store could not
be read.

When vision ingest has errors, the detail counts them by structured reason and
the row draws as a warning.

Below the table come the full state of the row under the cursor and the alerts
the server attached to it. `r` reloads.

`Enter` on a row opens that Keeper's **fact browser**. The list shows a fact's
content before its path. It separates ordinary facts by category, facts bound
to a file, and invalidation records. The Korean setting translates only the
built-in category names and the `source` and `dropped` marks (`원본`, `무효화`);
custom category names, content, origin and invalidation reasons keep their
original text. The selected row's source and time show under the list, and
`Enter` reads the whole content.

`c`/`C` cycle the filters: all, each ordinary category, source and dropped.
Choosing an ordinary category keeps only that category's ordinary facts;
source and dropped records have their own filters. `/` searches content,
category and source, and Keeper names too in the all-Keepers view. Ordinary
categories match by canonical name or Korean display name. Search on the
health table takes Keeper names and state names, canonical or displayed in
Korean or English. `Esc` closes an open detail or clears the search and returns
to the previous view.

The counts in the title and on the list (`N listed rows`) are the rows left
under the current filter. The count beside a category covers the whole store
as read; a read failure or a missing Keeper shows it as `?`.

### Workspace

Registered repositories and the checkout path the server actually resolved for
each. Workspace is a Tab ring stop, and Code hangs off it. The `Path` column
shortens the middle when it is too narrow, but `Path:` under the selected row
wraps the full path. A path stored as relative also shows `Stored as:`, and
`Keepers:` names the Keepers assigned to the repository.

Right or `Enter` opens Code scoped to the selected repository. `d` opens the
current Git changes of the selected repository (or of the project, when pressed
on the Keepers list or detail). Each row is staged, worktree, untracked or
conflict. The title carries the checked-out branch and `↑ahead ↓behind` against
its upstream; with no upstream it says `(no upstream)`, with a vanished
upstream ref `(upstream … gone)`, and off a branch `detached HEAD`, without
filling the numbers with 0. In that list, `Right`, `d` or `Enter` opens the
file's Git diff inline with syntax highlighting and line numbers; `j`/`k`
scroll it and `Esc`/`Left` return to the file list. `v` opens the file on Code.
Left or `Esc` returns to the previous screen (repository list, Keeper detail or
chat).

On Workspace, `H` reads the last 24 hours of file changes from the server's
shared tool-call record and shows only those for the selected repository's
exact ID. It does not filter by the Keeper roster, so changes by Keepers not
assigned to the repository, or since deleted or not loaded now, appear too
while they are within the 24 hours.

A repository's Git changes and a Keeper's work record are different facts.
Changes, below, shows what the selected Keeper recorded in the last 24 hours.

### Changes

Changes follows the Keeper selected on the Keepers surface. `[` and `]` move
that selection directly from Changes and reload the 24-hour change window;
the header always names whose rows are shown. Right or `Enter` opens the
selected recorded diff, and Left or `Esc` returns without moving the cursor (or back to Keeper chat if opened via `/changes`).

`v` opens the row's file on the Code surface, read through the keeper's own
workspace (`?keeper=`), so the bytes are the keeper's checkout rather than a
same-named file in the project tree — and the jump aims at the changed line
when the local copy can say where it is. `o` hands the file to `$EDITOR` /
Neovim instead. An absolute-path write has no address inside the keeper's
workspace, so `v` says so and leaves that row to `o`.

### Code

A file browser over the workspace the server serves, one directory level at
a time. `j`/`k` move the cursor,
`/` jumps it to a matching entry, Right or `Enter` drills into a directory or
opens the file,
and Left or `Esc` walks back out the way Enter came in. With a file
focused, `/` searches the file's own lines instead of the tree — typing
moves the line cursor to the first match, Enter keeps the query for
`n`/`N`, and the view follows the cursor.

Code's Ctrl-P finder and B return preserve the source reading while a file is
being fetched. See [Code navigation](guides/tui-code-navigation.md) for failure,
cancellation and reading-position behavior.

Which workspace is a scope the header always names: the project tree by
default, a keeper's playground after a Changes `v` jump (`alpha ▸ repos/…`),
or a registered repository after `Enter` on a Workspace row
(`masc ▸ /`). `Esc` at a scoped root returns to the project tree, and at the project
root it lands on Workspace, the ring parent.

With the project tree focused, `d` lists every Git-changed file in the current
project; the project does not need to be registered in Workspace. The list
separates staged, worktree, untracked and conflict, and `Enter` opens the
selected file. Left or `Esc` returns to the same project tree. With the file
pane focused, `d` opens that one file's diff, as below.

An open file arrives whole and is lexed once — OCaml (nested comments
included), bash, JSON, the curly-brace family (TypeScript/JavaScript,
C/C++, Go, Rust, Java, and their kin: `//` and `/* */` comments, strings,
numbers, keywords), and Python (`#` comments, triple-quoted strings)
colour; an extension without a lexer draws plain, and a file past 500 KB
draws plain rather than slowly.

With file content focused, `y` asks the terminal to copy the whole original
file through OSC 52. Tabs, indentation and original line endings are retained;
colours, line numbers and display sanitation are not copied. The status reports
the file and bytes sent, with terminal support unconfirmed. Close History, Diff or Notes
first. Mouse selection continues to copy displayed rows.

`e` opens the exact source in `$EDITOR` and retains the returned candidate as
a draft in this TUI session. `V` opens its comparison and `S` explicitly saves
against the opening server revision. Navigation retains the draft; `Esc`
closes only the comparison, and `X` discards an unsubmitted draft.

A conflict or uncertain save keeps the candidate. In that comparison, `r`
reads the server again without authorizing another write, and `A` explicitly
adopts the compared revision before another `S`. The quit warning includes retained drafts;
they are not recovered after the TUI process exits.

With a file open:

- `Shift-Left`/`Shift-Right` pan sideways by one display cell — the gutter stays put, the
  title says `(col N)`, and a double-width glyph on the boundary pads
  rather than splits.
- `H` swaps the content for one newest-first timeline: commits from
  `/api/v1/git/log` and durable Keeper `Edit`/`Write` calls from
  `/api/v1/ide/file-activity`. `Enter` on a commit answers with its pull
  request link (the subject's `(#N)` against the registered remote). `Enter`
  on a Keeper change returns to the file at its producer-recorded line.
  On a Keeper record, `d` expands its recorded edit/write text in the timeline;
  press `d` on any of that record's rows to collapse it. Failed calls are
  labelled as attempts.
  On a commit, `d` opens what that commit changed in this file, against its
  first parent, over the same diff overlay (`GET /api/v1/git/diff?commit=`).
  The title names the commit instead of `vs HEAD`, `r` keeps that commit
  on screen, and `Esc` returns to the history at the position it was left.
  Pressing `d` again after a failed read asks again.
  `t` opens the selected Keeper record's Task detail, including its recorded
  status, handoff, completion/evidence contract and transition history. `Esc`
  returns to the same file-history position and expanded record. `r` in History retries both sources;
  reopening `H` alone keeps the existing reading. A
  project tree is joined automatically only when the server base path exactly
  matches one registered repository's resolved path; otherwise it keeps Git
  history and explicitly says why Keeper activity cannot be joined.
- `d` swaps it for the working tree's diff against HEAD, drawn by the same
  renderer the Changes surface uses. A clean file says it matches its last
  commit.

- `m` lists memos written as standalone comments in the opened file, such as
  `-- masc(alpha) decision: keep the lock` in Lua. It works in project,
  Keeper and repository scopes. It shows the line, author, optional kind and
  text; malformed memos show their parse error. To add or edit one, edit the
  source file through the external editor.
- File memos mark their own gutter lines. Once history has been read (`H`),
  exact producer-recorded Keeper ranges also mark the gutter. Historical
  changes without line evidence remain `L?`; the pane does not invent a range
  or fetch history solely to decorate the file.
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

`Esc` closes the overlay first, then the
file, then climbs directories.

MASC ships no language server. It starts the one the project's language
names and expects that program on `PATH`; an absent one answers
`Command_not_found` rather than a guess.

| Language | Program | Project marker |
|---|---|---|
| OCaml | `ocamllsp` | `dune-project`, `dune-workspace` |
| TypeScript | `typescript-language-server` | `tsconfig.json`, `package.json` |
| JavaScript | `typescript-language-server` | `jsconfig.json`, `package.json` |
| Python | `pyright-langserver` | `pyproject.toml`, `setup.py`, `setup.cfg` |
| Rust | `rust-analyzer` | `Cargo.toml` |
| Go | `gopls` | `go.mod` |
| C | `clangd` | `compile_commands.json`, `CMakeLists.txt`, `Makefile` |
| C++ | `clangd` | `compile_commands.json`, `CMakeLists.txt`, `Makefile` |
| Swift | `sourcekit-lsp` | `Package.swift` |
| Java | `jdtls` | `pom.xml`, `build.gradle`, `build.gradle.kts` |
| Kotlin | `kotlin-language-server` | `build.gradle.kts`, `settings.gradle.kts`, `build.gradle` |
| Ruby | `ruby-lsp` | `Gemfile` |
| PHP | `intelephense` | `composer.json` |
| Lua | `lua-language-server` | `.luarc.json` |
| Bash | `bash-language-server` | workspace boundary |
| JSON | `vscode-json-language-server` | workspace boundary |
| YAML | `yaml-language-server` | workspace boundary |
| Zig | `zls` | `build.zig` |
| Haskell | `haskell-language-server-wrapper` | `stack.yaml`, `cabal.project` |
| Elixir | `elixir-ls` | `mix.exs` |
| Dart | `dart` | `pubspec.yaml` |
| Scala | `metals` | `build.sbt` |
| C# | `csharp-ls` | workspace boundary |
| Markdown | `marksman` | workspace boundary |

The same servers back the Keeper's `keeper_code_query` tool, so a Keeper
asked about a language whose server is missing falls back to reading text.
For OCaml, `references` also needs `dune build @ocaml-index`; without it the
answer names that command rather than returning a short list.

### Tools

`t` on System opens Tools, which belongs to Features & plugins. `p` moves
through six panes: the selected Keeper's effective Tool surface, async
requests, Skill activations, cross-Keeper Skill usage, the registered Tool
catalog, and storage (the host disk and the server's last storage cleanup).

On the effective Tool surface, `j/k`, paging and `Home/End` select a Skill.
`Enter` loads its retained evidence and turns those keys to the page below the
list, where the evidence and the tool table are; `Esc` returns them to the
Skill list with the selected Skill in view. `f` selects the next Composition,
loads its performance and opens its page at the performance card. The footer says which of the two the keys do: `j/k:move` and
`Esc:features` on the list, `j/k:scroll` and `Esc:list` on the page. The mouse
wheel scrolls the page in both. Another pane or screen starts on the list
again.

In async requests, `j/k` selects an original request and `Enter` opens its
detail. `r` refreshes that exact request; `Esc` returns to the active list.
The footer says where `Esc` goes: `Esc:features` on the request list,
`Esc:list` on an open request and `Esc:request` on its original Task.
The selection stays on the original submitter, request ID and target Keeper
when a terminal request disappears from the active list. `o` opens an editor
with those three JSON fields, so a known terminal request can also be read
directly without browsing history. The target Keeper cannot stand in for the
original submitter.

From request detail, `t` opens the original source Task and its event history;
`r` refreshes both and `Esc` returns to the original request.

The Skill Usage pane opens with a summary box: observed catalog entries,
distinct Keepers, and separate Triggered, Delivered, and Actions totals (`호출`,
`전달`, `동작` on the Korean screen; table headers follow the screen language).
Missing ledgers make the totals partial and are called out beside the summary.

Skill cards follow in descending invocation order. Each card shows its own
totals and Keeper rows, with the last use the ledger recorded.

The effective surface lists a skill's name, kind and sizes; a composition
also carries the shape of its plan (`nodes`, `batches`, `parallel`), which an
instruction skill has none of. `why loaded` is drawn only when something
other than the catalog chose the skill - a Keeper profile or a task - or when
nothing accounts for it at all.

The Skill activations pane reads as counts rather than as the ledger's field
names: per scope, `triggered / delivered / handed off / actions` for
instruction and composition, then what it served and which runtimes it ran
on.

### Runtime

Runtime candidate orders, joined to the latest provider
metadata reachability reading by exact `runtime_id`.

The lane fact on each row says why that candidate is
the one the lane walks: `head`, `fallback #n`, or `single candidate`.
`GET /api/v1/dashboard/runtime-probe` supplies only a cached provider
metadata-endpoint reachability reading. It does not send a completion, execute a CLI
runtime, or report runtime candidate order history.

Runtime detail also reads the authenticated `GET /api/v1/runtime/metrics`.
It shows the last and recent recorded successes within a 24-hour window,
successful/error sample counts, reported usage and telemetry coverage, and
cache reads as a share of inclusive input tokens from the same valid pairs.
Records without an
answerer and unavailable cost-store reads are shown separately. Snapshot age and
staleness accompany the history; a cold cache shows loading until refreshed.

The same detail lists current catalog context/output limits separately from
model, provider and binding context declarations. Official-client catalog
limits that the runtime does not expose remain unreported. Bound Keeper totals are labelled
as lifetime activity across all runtimes, separate from this runtime's history.

`CLI not probed` is neutral, and a candidate absent from a stale probe is
`unobserved`, not unhealthy.

The freshness badge is the server's closed value: `fresh`, `recent`, `stale`
(`served_stale` on the wire), or `warming` (`warming_up`). `r` sends
`force=1`, but the route remains non-blocking: a stale or warming response
means background work was scheduled and a later poll carries the new value.

`j`/`k` selects a row in both `Lanes` and `All runtimes`. Right or `Enter`
opens an untruncated detail view bound to that exact runtime identity. It shows
the complete runtime id, provider and model, every lane using it, candidate
position, dispatch blocker/default state, last-success timestamp, and the
probe's status, transport, timestamp, latency, HTTP result, and error when
those observations exist. `PgUp`/`PgDn` pages the detail; Left or `Esc` returns
to the same list row.

### System

System has seven panes. Press `p` to move through `runtime.toml`, `models`,
typed `params`, prompt overrides, presets, themes and voice.

Open typed parameters with `:settings`.

The `runtime.toml` view shows the source revision, validation result, and routing
and Keeper application status returned with that source. `v` opens the complete
read status: individual validation issues, restart requirements, pending keys,
and settings preempted by environment variables. Use `j/k` or `PgUp/PgDn` to
scroll, `v` or `Esc` to return, and `r` to reload.

`e` opens the raw source or retained draft in `$EDITOR`. Preview and save
failures keep the edited text in this TUI session, scoped to the workspace and
configuration path. Moving to another screen or temporarily losing workspace
authority does not discard it; quitting the TUI ends the session.

With a retained draft, `r` reads the current file without changing the draft or
its save basis. `C` switches between the draft and that current snapshot.
After comparing and combining changes in the editor, `u` adopts the displayed
current revision while keeping your draft; `S` retries saving it. `U` instead
replaces the draft with the displayed current text, and `X` discards the local
draft and reads the file again. A lost response or uncertain durability keeps
the draft and asks you to read the file before retrying.

The `runtime.toml` view keeps comments and section headings on screen, while
`j`/`k` select only rows that contain actual assignments. `PgUp`/`PgDn` jump
by a visible page and land on the nearest assignment.

`a` on the `runtime.toml` pane adds one more Claude Code, Codex or Antigravity
account: pick a
provider the file declares with `←`/`→`, keep or change the suggested id, and
type where the new account signs in (`account-home` for Claude Code and
Codex, the OAuth file `masc runtime-antigravity-account --sign-in` reports for
Antigravity). The form copies that provider's command and model bindings,
refuses a location another provider of the same client already uses, and
saves through the same preview. It does not sign in; the rows under the
fields name the command that does, and after the save the same command is
in the session log. Turns reach the new account only after a lane lists it
as a candidate.

Models groups saved model bindings by account/provider and shows the API model,
declared context, reasoning effort, temperature, and output cap. `e` opens the
selected binding's settings; `c` copies it into an independently named variant
on the same account; `m` opens its source section in `runtime.toml`. In the form,
Tab or Up/Down select a field, Ctrl-U clears it, Enter advances and saves from
the last field, and Esc cancels. On Context, Left/Right cycle through 272k,
500k, 750k, 1M and custom input; returning to custom restores the typed value.
Copy suggests a context-based name after choosing a preset, until the operator
edits the name. These are requested limits; Runtime shows the effective context
and any capability clamp. Add a saved copy to a Lane to use it.

If the source changed, close and
reopen the form after reload. A missing or unreadable save reply is shown as an
unknown outcome: the draft remains and System, Runtime and Lanes are reloaded
to inspect the result. No write is retried automatically.

Context and output edits belong to the selected account/model binding.
Reasoning effort and temperature belong to `[models.NAME]` and affect every
account sharing that model; use Copy for independent settings. The detail names
each owning section and whether declared context comes from the binding,
provider, or model. `-` means a setting is absent; undeclared context directs
you to Runtime's resolved value. Params come from the typed live
registry, and `Enter` edits one value while `x` restores its registered default.

Prompt overrides open as a reduced operator catalog: the complete prompts
for Keeper, Librarian, verification, and judges are visible by default. The
assembly fragments in `config/prompts/` remain live, editable fragments; `a` toggles
them into the list without presenting headings and row snippets as complete
prompts. The detail pane renders the effective
body as Markdown (including fenced-code syntax highlighting), names whether it
came from a file or an override, and keeps `PgUp`/`PgDn` paging. `e` edits the
effective prompt through `$EDITOR`, and `x` clears only its persisted override.

Workspace's repository list and System → Models offer `v` for a full, read-only
capture of the selected object. Long paths, assignment lists, failure reasons,
account names and owning TOML sections wrap without the preview's row limit.
`/` searches this captured document, Enter keeps the query for `n`/`N`, and
Esc while typing cancels the query.
`j/k`, arrows, PageUp/PageDown and Home/End read the complete capture; Esc or `v`
returns to the same selection. The capture stays fixed while background reads
or selections change. Close, refresh and reopen for updated data.

### System Logs

Activity combines Events and Logs: `e` opens Events from either view, and `l` opens Logs from Events; Esc on Logs returns to Events.

The server's log ring, the same source the dashboard `logs` tab reads.

When the load fails the previous page stays on screen under a red line saying
so. The count above it is then stale, not a fresh reading.

## Requirements

Interactive TTY stdin and stdout, and a terminal other than `dumb`.

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

**`masc` started a server instead of the TUI.** The handover looks for a
`masc-tui` beside the running binary and then on `PATH`. An install lays both
names down together; a source checkout builds `_build/default/bin/masc_tui.exe`,
which matches neither, so the bare name serves — the same rule that keeps a
container or a unit file from opening a TUI. Run the built path, or link both
names into one directory on `PATH`; the README's source-checkout section spells
out the two commands.

**The TUI does not show a change that is already on `main`.** The TUI is its
own binary. `start-masc.sh` builds and restarts the server (`bin/main_eio.exe`)
and does not touch it, so a server restart leaves the TUI on the binary it
started with. Rebuild with `dune build bin/masc_tui.exe`, then quit and reopen
the TUI. To restart every local TUI process at once, inspect the target PIDs
with `scripts/tui-graceful-restart.sh --dry-run` before running
`scripts/tui-graceful-restart.sh --build`. The script searches the system for
all processes named `masc_tui.exe` or `masc-tui`, including other checkouts and
installed copies. `--base-path` selects the exit-log location and new TUI
workspace; it does not narrow the processes to stop. A session that does not end within `--timeout` is left
alone — the script never escalates to `SIGKILL` and never starts a new TUI
while a matched session remains live.

**Why a TUI session ended.** Every session writes one line saying why it ended to its own stderr log,
`.masc/logs/masc-tui-<pid>.log`, prefixed so it can be collected on its own:

```
[masc-tui] exit: normal (quit key)
[masc-tui] exit: normal (interrupt)
[masc-tui] exit: normal (signal SIGTERM)
[masc-tui] exit: abnormal (exception Failure("..."))
```

A normal end is the operator or the session's owner asking for it — the `q`
key, a second `Ctrl-C`, or a terminate signal — and an abnormal one is the
surface leaving without being asked, such as an uncaught exception. A session
that leaves without naming a cause reads as `abnormal (no cause was
recorded)`, which is its own wording rather than a made-up exception.

Counting a day's ends by cause is one command:

```
grep -h '\[masc-tui\] exit:' .masc/logs/masc-tui-*.log | sort | uniq -c | sort -rn
```

A session killed with `SIGKILL`, or one whose machine lost power, writes
nothing — no handler runs — so the count covers ends the process survived
long enough to name.

**Header shows `HTTP refresh failed`.** The server is not answering on
`127.0.0.1:<port>`. Keepers and the Tasks panel keep working; Approvals, Board,
Planning, Fusion, and messaging do not. Check the port with `--port`.

**Keepers list is empty but the runtime is running.** The base path is probably
wrong. The list reads `.masc/keepers/` below `--base-path`, with no server
involved, so an empty list with no error means the directory is empty.

**Tasks panel prints `task backlog unavailable`.** The message carries the full
path and says which case it is: `no backlog at <path>` when
`.masc/tasks/backlog.json` does not exist, `backlog decode failed for <path>`
when it exists but does not match the schema, and `backlog read failed for
<path>` when it is blank, unparsable or unreadable.

**A surface says `(not loaded yet)`.** Nothing has been read for it: the
request is still out, or the surface was opened before a server was reachable.
It is not an empty result. A read that came back with nothing says so in its
own words - `(nothing waiting on a verdict)`, `(no verdicts recorded)` - and
only after the header has stopped saying `(not loaded)`.

**A surface shows a count of `0` next to `data unreliable`.** The read failed;
the count is not an observation. The failing call is printed on the same row and
recorded in the TUI session block.
