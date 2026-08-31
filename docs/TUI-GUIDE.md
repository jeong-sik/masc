---
status: runbook
---

# MASC TUI Guide

Terminal UI over a MASC runtime root. It reads `.masc/` directly and, when a
server is reachable, adds the surfaces that only exist over HTTP. Surfaces
rotate with `Tab` in the order `surface_ring` spells in
`bin/masc_tui_types.ml`: Overview, Acting, Keepers, Lanes, Approvals, Board,
Planning, Schedules, Harness, Fusion, Repos, Code, Changes, Connectors,
Runtime, Config, Resources, Tools, Logs.

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
| Schedules | unavailable | `GET /api/v1/dashboard/scheduled-automation` |
| Fusion | unavailable | `GET /api/v1/dashboard/fusion-runs`, then exact `/:run_id` detail |
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
Resources surface lists every MCP resource; `Enter` reads one beside the
list. `Ctrl-W` switches between the list and text, and `j`/`k` move whichever
pane has focus. Resource text uses the same Markdown renderer as chat and
Board. On Connectors, `b`/`u` open an editor form that binds or unbinds a
channel.

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
reason is in Recent Events and on the Acting status row) -
the count stays so a stream that dropped after a thousand events and one that
never opened do not read alike. The feed is opened after the first refresh
that reaches the server and reopened on the refresh cadence after it closes;
both transitions land in Recent Events. Every keeper's tool calls, turn
boundaries, heartbeats, and turn settlements arrive on it; this build keeps
the last 1,000 and counts what falls off the end.

Tasks show terminal states in Planning rollups but not in this list. A task
detail that is open when its task turns terminal stays open - the detail reads
the full backlog rows, not the active projection.

### Acting

Every keeper's actions as the runtime event feed delivers them, newest first:
tool calls and their returns, turn boundaries and settlements, chat rows
landing. This is the surface for watching ten keepers at once without
opening ten chats.

```
 MASC Acting (212 of 640 held, actions)  01:12:04  [connected]
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

`f` switches between `actions` - what keepers did - and `everything`, which
adds heartbeats, composite and snapshot pushes, and telemetry. On the live
runtime those were more than half of the feed and said nothing a row could
act on, so `actions` is the default. An event kind this build was not taught
draws under both, by its name, so a new kind is noticed rather than hidden.

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
    HEALTH       KEEPER             A P TURNS LIFECYCLE / RUNTIME              TASK
 >  ● healthy    adm-race-cf-001    A P   498 running anthropic.claude-opus-5  task-471
    ● idle       analyst            A -   237 paused kimi.kimi-k2.5             task-464
  j/k move  p pause  w wake  s shutdown  g yolo  c chat  right/enter detail
```

The metadata list needs no server, so names, turn counts, and tasks stay
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

The current composite lifecycle and turn-cycle reading for every Keeper. Open
it with `Tab` immediately after Keepers.

```
 MASC Lanes (10 keepers)  17:02:53  [connected]
  KEEPER             LIFECYCLE   TURN STEP   IDLE   LAST OUTCOME         DIAGNOSIS
  taskmaster         ● running   executing   7m     done · deepseek-v4   running_fiber_alive
  kidsnote           × failing   executing   59m    done                 failing_unhealthy
```

The rows come from `GET /api/v1/keepers/composite`. `LIFECYCLE` is the Keeper
process state, `TURN STEP` is the current autonomous or requested turn step,
and `IDLE` is the producer's idle
duration in seconds rendered as seconds, minutes, hours, or days. `LAST
OUTCOME` keeps the latest runtime state and model when one exists.
`DIAGNOSIS` is the condition the producer says determined the lifecycle
phase. A phase or turn value this TUI does not know is shown verbatim with a
`?`; it is never changed into a familiar state.
The lifecycle glyph alone carries its semantic colour. The exact phase word
uses the terminal foreground, so a healthy fleet does not turn the table green
and an attention glyph remains easy to find. Under `NO_COLOR`, the same glyph
shape and phase word remain.

Before the first response the page says `(not loaded yet)`. A successful empty
response says `(no keeper lane snapshots)`. A failed refresh leaves the prior
rows on screen, adds the error in red, and says that an empty body is not a
reading. Move the lane cursor with `j` / `k`. Right or `Enter` opens that
Keeper in the existing Keeper detail view. `c` or `m` opens its chat directly;
`Esc` returns to the same Lanes selection. Both paths join the lane's Keeper
name exactly to the current local roster. If that Keeper is absent, the keys do
not open another row; the Lanes pane keeps its selection and names the missing
Keeper in an action error. Moving the lane cursor, receiving a new lane
reading, or observing a changed roster clears that target-specific error.

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
as the Keepers table. It never derives a model by parsing the id. In a narrow
split pane, only the displayed id is middle-fitted so active reasoning and tool
visibility modes remain truthful in the header. While no
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

The pane opens on the keeper's durable transcript. A turn the keeper ran on
its own is drawn as what it did, not as a blank line. Reasoning starts hidden
and tool calls start as one compact activity row, so the answer remains the
strongest level in the pane. `Ctrl-R` cycles reasoning through hidden, folded,
and full; `Ctrl-D` toggles compact and full tool details. `/thinking` and
`/tools` expose the same choices by name. `--reasoning` and `--tool-view` can
override the initial modes.

The folded tool row retains exact outcome counts. The typed calls themselves
stay attached to the message, so changing the view does not reconstruct facts
from rendered glyphs. Expanded calls use the finished glyph for a call that
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

Only a request-correlated terminal keeper result is rendered as a reply.
Interrupted streams, protocol errors, rejected turns, and terminal outcomes
without visible text become explicit status or error rows; partial text is never
promoted to a successful reply. Requests are tracked per keeper, so a turn
running for one keeper does not decide what `Enter` does in another's window;
sends going elsewhere show as `(also sending to X)`. Drafts are retained per
keeper while navigating.

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

Enter during a running turn holds the line for the next one rather than
refusing it. The pane draws every waiting line in full, oldest first, under the
sending rows:

```
   (sending tui-..d3530056 · 12s…)
   queued 1: check the CI run too
   queued 2 -> polisher: and the rebase
   > _
  Enter:queue (2 waiting)  Ctrl-K:cancel last  Ctrl-P:edit last  …
```

A count on its own is not enough - an operator who typed three lines during a
turn needs to see which three. Only the first line of a queued message is
shown, with `…` where it was cut; the rest goes with it when it is sent.

A queued line travels with the keeper it was written to, so switching keepers
mid-turn cannot redirect it; a line addressed elsewhere names its keeper after
the number. `Ctrl-K` drops the newest waiting line and `Ctrl-P` pulls it back
into the composer. Nothing has been dispatched, so both are local.

Each waiting line takes its row from the conversation above it, never from the
terminal: the pane ends on the same row whether the queue is empty or full.

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
 >   p-687c6844e~  polisher     [B1 mission draft v9] RW20 PoC scenario     +9  c39
     p-0323d8b3c~  dashboard    RFC-0370 Draft: rotation census             +4  c22
  j/k:move  Enter:read  r:refresh  Tab:next  | Port: 8935
```

Selection follows post identity across refreshes. Opening a post binds the
detail view to that post's request, so a late response for a post you already
left is discarded rather than rendered under the current title.

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
that line instead of being flattened into one truncated row.

### Planning

Planning is one workspace with two child views: `Goals` and `Task Review`.
Press `v` to switch between them. They share navigation but not authority:
Goals manages Goal lifecycle, while Task Review records an operator verdict
on a Task completion request.

```
 MASC Planning  ▸Goals  Task Review·2  10:44:57  [connected]
   Executing: 3  Paused/Blocked: 1  Verifying: 0  Done: 24  Dropped: 22
   Backlog: todo=4  claimed=0  running=6  done=109  cancelled=37
 >   [dropped ] P1  Reduce all kidsnote service backlogs to 0
     [executi~] P1  Multi-Keeper real-world mission keeper-collab-e0-r7
  j/k:move  Enter:detail  r:refresh  Tab:next  | Port: 8935
```

The cursor tracks goal identity in visible order, so a refresh that reorders
goals keeps the same goal selected.

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
to wake up".

```
 MASC Schedules  [me]  10:44:57  [connected]
   Requests: 34  (page shows first 20)
   Next due: 2026-08-24T09:57:00
 >   [scheduled] 2026-08-24T09:57:00  alpha        daily 09:57
     [running  ] 2026-08-24T09:12:00  sangsu       one-shot
  j/k:move  Enter:details  x:cancel  r:refresh  Tab:next  | Port: 8935
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

Right or `Enter` opens the selected schedule. The detail includes schedule and instance
identity, dispatch state, requesting actors, timestamps, recurrence, payload
kind/tool/digest/summary, last wake, and queue/reaction evidence. Left or `Esc` returns
to the list; `j`/`k` scroll by a row and `PgUp`/`PgDn` by a page.

### Fusion

The retained Fusion run registry is the list. It shows only facts that list
actually owns: start time, lifecycle status, keeper, preset, topology, and run
id. The cursor follows run id across refreshes, so a newly sorted row cannot
silently change what `Enter` opens.

```
 MASC Fusion (19 runs)  18:31:04  [connected]
   TIME     STATUS    KEEPER           PRESET     TOPOLOGY   RUN
 > 16:42:11 completed rw-e0-r9         trio       simple     kmsg-386bed...
   16:40:07 failed    analyst          trio       simple     kmsg-942ab1...
  j/k:move  Enter:detail  r:refresh  Tab:next  q:quit  | Port: 8935
```

The detail is a separate exact read. Lifecycle remains the Registry fact;
evidence comes only from a Board post whose typed origin is
`source=fusion` with the same `fusion_run_id`. `recorded` puts the judge result,
resolved answer, and reason first, followed by the question and every panel
answer or failure in server order. The panel header summarizes answered/failed
counts and tokens; it does not calculate a majority, minimum answer count,
timeout verdict, cost verdict, or any other local conclusion. `PgUp`/`PgDn`
scroll a page at a time.

`pending` is legal only while the Registry row is running. `absent` means the
retained completed/failed run has no current Board projection; it does not
claim the post was never written, that the sink failed, or that retention
expired. A failed refresh leaves the prior reading visible under an explicit
error instead of redrawing it as an empty result.

### Repositories

등록된 저장소와 서버가 실제로 해석한 체크아웃 경로를 보여준다. 목록의
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
or a registered repository after `Enter` on a Repositories row
(`masc ▸ /`). `Esc` at a scoped root returns to the project tree. The three
scopes are one field, so the surface cannot read two workspaces at once.

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
- `H` swaps the content for the commits that touched the file
  (`/api/v1/git/log`), newest first. `Enter` on the top visible row
  answers with the commit's pull request link (its subject's `(#N)`
  against the repository's registered remote). An untracked file honestly
  answers that no commit touches it.
- `d` swaps it for the working tree's diff against HEAD, drawn by the same
  renderer the Changes surface uses. A clean file says it matches its last
  commit.

- `m` swaps it for the notes anchored to the file — who left each one, its
  kind, the line span, and the task it rides with. Notes are keyed by the
  server-minted codebase slug, which only a Repositories row carries, so
  `m` answers in repository scope and says why not in the others. Inside
  the notes view `w` adds one through the `$EDITOR` form (kind: Comment /
  Decision / Question / Bookmark); the acting identity is the bearer's.
- Once the notes have been read (m), the lines they anchor to carry a
  gutter mark — an accent dot. The pane decorates only what is already
  loaded; it does not fetch to decorate.
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

### System Logs

The server's log ring, the same source the dashboard `logs` tab reads.

```
 MASC System Logs (300 of 774273, seq 774272)  03:09:37  [connected]
   Time     Level Module           Keeper       Message
   03:09:21 INFO  Discord          system       presence update: idle
   03:09:18 WARN  Keeper           alpha        turn budget exceeded, deferring
   03:08:57 ERROR Board            system       board post write failed: ...
  j/k:scroll  Tab:next  q:quit  r:refresh  | Port: 8935
```

The header counts two different things. `300` is what this page holds; `774273`
is what the ring has seen. A page count on its own would read as "that is all
there is".

Levels are coloured: `ERROR` red, `WARN` yellow, `DEBUG` dim. A level the
server emits that this build does not name keeps its own text and renders
unstyled, so it shows up as itself rather than as an ordinary line.

When the load fails the previous page stays on screen under a red line saying
so. The count above it is then stale, not a fresh reading.

## Keybindings

Cross-surface shortcuts. An active field or panel handles its own keys first:

| Key | Action |
|-----|--------|
| `Tab` | Next surface: Overview -> Acting -> Keepers -> Lanes -> Approvals -> Board -> Planning -> ... -> System Logs -> Overview |
| `2` | Jump to Keepers when the active field or panel does not use the number |
| `r` | Force refresh |
| `q` twice | Quit; any other input after the first `q` cancels |

Per surface:

| Key | Surface | Action |
|-----|---------|--------|
| `j` / `k` | Overview | Scroll Recent Events |
| `j` / `k` | Keepers, Lanes, Approvals, Board, Planning, Schedules, Fusion list | Move cursor |
| `j` / `k` | Runtime, System Logs | Scroll the page |
| `j` / `k` | Keeper detail, logs, Board read, Planning detail, Fusion detail | Scroll content |
| Right / `Enter` | Keepers | Open keeper detail |
| Right / `Enter` | Lanes | Open the selected lane's Keeper detail |
| `c` / `m` | Lanes | Open the selected lane's Keeper chat; `Esc` returns to Lanes |
| Right / `Enter` | Board | Open post body |
| `Ctrl-W` | Board read, Resources | Switch the focused pane |
| `h` / `l` | Wide Board read | Focus post list / post detail |
| `PgUp` / `PgDn` | Board, Schedules, Fusion | Move the active list or detail by a page |
| Right / `Enter` | Schedules | Open schedule details |
| Right / `Enter` | Planning | Open goal detail |
| Right / `Enter` | Fusion | Open exact run evidence detail |
| `[` / `]` | Changes | Previous / next Keeper |
| Right / `Enter` | Changes | Open the selected recorded diff |
| `v` | Changes | View the row's file on the Code surface, in the keeper's workspace |
| `a` twice | Verification | Approve the row under the cursor |
| `x` | Verification | Reject it, with a reason through `$EDITOR` |
| Right / `Enter` | Repositories | Browse the repository's tree on the Code surface |
| `d` | Repositories | Show the repository's current Git working-tree changes |
| Right / `Enter` | Code | Drill into a directory / open the file |
| Left / `Esc` | Code | Close the overlay, then the file, then climb a directory |
| `/`, `n` / `N` | Code | Jump the tree cursor to a match |
| `h` / `l` | Code, file open | Pan the file sideways by one cell |
| `H` | Code, file open | The commits that touched the file, newest first |
| `d` | Code, file open | The working tree's diff against HEAD |
| `m` | Code, file open, repository scope | The notes anchored to the file |
| `w` | Code, notes view | Add a note through the `$EDITOR` form |
| `K` / `D` | Code, file open | Ask the language server: hover / definition of a name on the cursor line |
| `l` | Keeper detail | Open logs |
| `c` / `m` | Keeper list or detail | Open message input for the selected keeper |
| `y` / `n` | Approvals | Confirm / deny the selected request |
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

  Overview -> Acting -> Keepers -> Lanes -> Approvals -> Board -> Planning
           -> Schedules -> Verify -> Harness -> Fusion -> Repos -> Code
           -> Changes -> Connectors -> Runtime -> Config -> Resources
           -> Tools -> Logs -> Overview

Within a surface:

  Keepers   --Right/Enter-->  Keeper detail  --l-->  Keeper logs
  Lanes     --Right/Enter--^
  Lanes     --c/m----------->  Message input  --Esc-->  Lanes

  Keeper list/detail  --c-->  Message input

  Board     --Right/Enter-->  Board read
  Planning  --Right/Enter-->  Goal detail
  Fusion    --Right/Enter-->  Run evidence detail
```

`2` reaches Keepers after the active field or panel has declined it.
`Esc` returns one level within Keepers, Board, Planning, and Fusion.

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
