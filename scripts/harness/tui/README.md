# TUI idle measurement

These tools measure what each TUI screen costs while nobody presses a key. They serve the redraw rules of [the one-screen grammar RFC](../../../docs/rfc/RFC-tui-one-screen-grammar.md) (§8, §9 item 8) and the baseline of [the idle-TUI RFC](../../../docs/rfc/RFC-an-idle-tui-receives-only-changes-it-draws.md) (§7, §8 L0). Python 3.12 or later on macOS or Linux is required. Nothing here builds, starts or stops a MASC server.

| Tool | What it does |
|---|---|
| `readonly_proxy.py` | A loopback relay in front of a MASC server. It forwards reads and refuses writes, and logs every decision and every answer's bytes. |
| `frozen_server.py` | Replays what the relay recorded and never sends new data, so a TUI in front of it redraws only because time passes. |
| `idle.py` | Starts one TUI per screen through the relay, brings it to its screen and measures an idle window. |
| `summary.py` | Prints one line per screen, and with `--reads` what the TUI read in each window. |
| `key_steps.py` | Presses navigation keys after a window and captures the screen after each (`idle.py --keys`). |
| `screen_steps.py` | The screens `idle.py` measures, the keys that reach each, and the allow-list those keys must stay inside. |
| `vte.py`, `pty_driver.py` | The terminal emulator and the pseudo-terminal driver `idle.py` uses. |
| `relay_files.py` | The decision log and the recording format that the relay and the frozen server share. |

## The relay

`readonly_proxy.py` forwards GET and HEAD. It forwards a POST to `/mcp` only when every JSON-RPC message in it is a request for a read method (`initialize`, `ping`, the `*/list` methods, `resources/read`) or a `tools/call` of a tool in `READ_TOOLS`. `READ_TOOLS` lists tools that `lib/tool/tool_catalog.ml` registers as read-only. The relay answers 403 to everything else and does not forward it: other POSTs, PUT, PATCH, DELETE, websocket upgrades, JSON-RPC responses, bodies that name a member twice in one object (`json.loads` would judge the last `method` or tool name, while a server may run the first), and bodies that declare more than 1 MiB (`body-too-large`, `MAX_BODY_BYTES`), which the relay does not read. A refused request shows in the log with its path and reason, so a run also shows which writes a screen tried. The TUI posts `/api/v1/tui/preferences` when a person picks a language, theme, candle or Board sort, when a Keeper chat opens from Home, and on the first key while the workspace still shows its help hint (`store_preference` and `remember_local_chat_visit` in `bin/`). The relay refuses those posts, so a measured run leaves the server's stored TUI preferences as they were.

Each `done` line in the log is one answer: its path with the query, status, bytes and arrival time. An event stream also gets `progress` lines, about once a second, with its events and bytes so far per event name. Events are named by `scripts/harness/perf/tui_request_events.py`, the same parser [the TUI request probe](../perf/README-tui-requests.md) uses.

## Measuring screens

```sh
python3 scripts/harness/tui/idle.py \
  --tui "$MASC_TUI_BINARY" --base-path "$MASC_BASE_PATH" \
  --upstream-port "$SERVER_PORT" --out "$IDLE_OUT" \
  --idle 20 --steps overview,keepers
```

`--out` must be a new directory. Without `--steps`, all screens in the `STEPS` table of `screen_steps.py` run in table order. A row of that table names a screen and the keys that reach it. Each screen starts a fresh TUI, so its keys start from the screen the TUI opens on: a command palette jump (`:go Work`), then single keys for that screen. The palette entries come from `bin/masc_tui_palette.ml` and the keys from `bin/masc_tui_keys.ml`. The Keeper list opens on the view `tui-keepers.toml` stores, so the table has no row per Keeper list view.

A step jumps to a `Destination` and then presses `Move`s. A destination is one whole `go ...` palette entry, because the palette runs whichever entry ranks first for the typed text and some entries act (`gate ...`, `language: ...`, `keeper ...`). A move is allowed only from the screens `MOVES` lists for it, because one key means different things on different screens: `p` switches Usage to Telemetry but pauses a Keeper on the Keeper list. `idle.py` refuses a step whose moves leave `MOVES` before any TUI starts. A row opens with Right, not Enter: on the Keeper list Enter opens the Story window, and on the Keeper detail's Services tab it starts a login. The Keeper detail rows (`keeper_info` to `keeper_terminal`) press Right twice and then walk `[` or `]` to their tab. The list puts its cursor on row 0, and when that row's group starts folded (the age view folds UPDATED WITHIN 24H), the cursor stands on the group's heading: the first Right unfolds it and rests on its first row, and the second opens that Keeper's detail. When row 0 is no heading, the first Right opens the detail and the second does nothing there.

`MOVES` records what the code says a key does, so `idle.py` also checks where the keys left the TUI. The keys stop at the first that fails, such as a jump that finds no palette, and then no window runs: the moves after it would reach the screen the failure left. Every place in `screen_steps.py` names the surface the TUI draws there, the `surface_key` its frames carry into the frame report. The surface on screen when the window starts must be the one the step's last place names. A surface covers a whole screen, not its tab or view: every Keeper detail tab is `keeper-detail`, and Usage is `metrics` on Plan, Calls and Telemetry alike, so `top_rows` still tell those apart. A step can land elsewhere because the workspace lacks what it opens: `work_request_detail` stays on `approvals` when no request waits.

`idle.py` exits 0 when every screen opened, reached its keys and landed on its surface, and the relay's refusals were read. It exits 2 when the run stopped early (a bad argument, `/health` not answering through the relay, a stop signal) and 3 when it ran to the end but a screen failed, the relay log could not be read or the preferences could not be put back; `idle.json` says which.

A run that exits 0 may list refusals in `relay.refused`, most often those preference posts as `rest-write`. A workspace that still shows the help hint posts one on each screen's first key, the palette's `:`. The refusals are the evidence that only reads went through, so they do not fail the run, and a run without any is just as normal.

The relay ends every log line with a newline. When the last line has none and is not JSON, the relay was stopped while it wrote that line, for example by the SIGKILL that follows its 5 s grace. The run still exits 3, and the error names the relay's exit. `summary.py --reads` reads that exit from `idle.json`.

For each screen, `idle.json` records:

- `opened` (the first frame arrived), `keys` and `keys_ok` (each palette jump found the palette open; `keys` ends at the first that failed), and `top_rows`, the first three screen rows when the window starts, which show where the keys landed;
- `landed`: the surface the step's last place names (`expected`), the one on screen when the window started (`shown`, null when the frame report does not say), and `ok`;
- `window`: wall-clock start and end, the same span in nanoseconds since the TUI started, and whether the terminal closed during it;
- `idle`: PTY bytes and bursts in the window (a burst is output after at least 8 ms of silence), and the CPU percent that `ps` reports for the TUI;
- `rss_mb` when the window ends, and `row_changes`: the rows that changed most, with the first column that changed and the text there;
- `frames`: the frames the TUI recorded in the window through `MASC_TUI_FRAME_TIMING`, with build and present times, bytes presented and surface tags, and `surface_at_start`, the surface of the last frame presented before the window. The TUI keeps only its first 512 frames per phase. When the window reaches past them, `covered` is false and the counts are a lower bound;
- with `--probes N`, `key_latency_ms` for N Down and N Up presses, each timed from the write to the first byte back. A press is skipped while the screen is still drawing, and a press that draws nothing within 1 s is not counted;
- with `--png-font FONT` (needs Pillow), `<screen>.png`: the screen at the window start drawn with that font. Use a font that has the glyphs of the workspace's language. Repeat `--png-font` to add fallback fonts: the first sets the cell size and each glyph uses the first font that has it. Many monospace fonts lack braille, so graph rows draw blank without a fallback that has it (on macOS, `/System/Library/Fonts/Apple Symbols.ttf`);
- with `--keys`, `key_steps`: what each key did, described below.

```sh
python3 scripts/harness/tui/summary.py "$IDLE_OUT"
python3 scripts/harness/tui/summary.py --reads "$IDLE_OUT"
```

`--reads` adds, for each window, the requests that arrived in it by path, the requests the relay refused, and per event name the events and bytes of each event stream. Stream counts come from the relay's `progress` lines, so the span they cover can start and end up to a second away from the window. The rates divide by the span between the two lines, not by the window.

## Pressing keys after the window

```sh
python3 scripts/harness/tui/idle.py ... --steps overview --keys j,j,k --png-font "$FONT"
```

`--keys` takes key names separated by commas: `j`, `k`, `PgUp`, `PgDn`, `Home`, `End` and `Tab`. Any other name stops the run before it starts. Keys that act on some screens, such as `p`, `w`, `s`, `x`, `g` and `U`, cannot be pressed, and neither can Esc. `MOVES` does not hold these keys or the Down and Up of `--probes`: they are pressed on every screen as navigation, and a screen may move a different cursor with them, such as the provider cursor of the Keeper detail's Services tab. On the palette `j` and `k` would become query text, so `--keys` are not pressed there and `key_steps` holds `skipped`. After each screen's idle window, before the probes, `idle.py` waits for the screen to go quiet, captures it, and then presses the keys one at a time. After each key the TUI has 1 s to draw. Once it draws, the capture waits for 0.5 s without output, for up to 5 s.

`key_steps` in `idle.json` holds:

- `start`: the capture before the first key, with its `outcome`, `png` and `layout`;
- `keys`, one entry per key:
  - `key` and `outcome`: `quiet` (it drew, then went quiet), `nothing` (it drew nothing within 1 s), `busy` (still drawing after 5 s, so the capture may be mid-frame) or `closed`;
  - `png`: `<screen>.key<N>-<key>.png` with `--png-font`; the start is `<screen>.key0.png`;
  - `changed_rows`: rows whose cells differ from the capture before this key, colours included. A key that only moves the selection highlight changes rows here;
  - `text_changed_rows`: the subset whose text differs;
  - `layout`, `kind_changed` and `card_rows_changed`;
- `kinds`: the layout kind of the start and of each captured key, in order, and `kind_stable`, true when they are all the same.

The layout kind is read from box-drawing glyphs alone, never from words. `bin/masc_tui_card.ml` draws a full card's top edge as `╭─ … ╮` and its bottom as `╰─ … ╯`, and a squashed card as the single row `╶─ … ╴`. A card edge is an opening glyph followed by `─`, then its closing glyph later on the same row, before any other opening. The closing glyph usually follows a `─`, but an edge whose name fills it up to the corner ends in ` ╮`. A screen with at least one edge is `cards`, and a screen with none is `plain`. `layout` lists each edge with its row, columns and shape, and `card_rows`, the rows that hold one. A chat's turn rail draws `╭` and `╶` followed by a space, so it is no edge. A pane frame drawn with the same rounded corners does count as an edge, so compare kinds only on screens whose plain layout draws no rounded box, such as the overview.

A terminal that closes during the keys ends them and fails the screen, and the captures before it stay in `key_steps`. When it closed during the idle window, no key is pressed after it: the screen fails when `--keys` or `--probes` asked for presses, and the error names the window. Without them, a close in the window is recorded only in `window.terminal_closed`.

## Record once, replay with the frozen server

A live server changes while it is measured. To compare runs, record once and replay the recording:

```sh
python3 scripts/harness/tui/idle.py \
  --tui "$MASC_TUI_BINARY" --base-path "$MASC_BASE_PATH" \
  --upstream-port "$SERVER_PORT" --out "$RECORD_OUT" --record "$RECORDING_DIR"

python3 scripts/harness/tui/frozen_server.py \
  --recording "$RECORDING_DIR" --log "$FROZEN_LOG" --port 0
# prints: listening <port>
```

`--record` keeps each 200 or 404 answer to a GET or an allowed `/mcp` call, and the headers of each event stream. The frozen server answers:

- a GET with the last answer recorded for the same path and query, else for the same path, else 404;
- an `If-None-Match` that equals the recorded ETag with 304, keeping the recorded `x-masc-*` headers;
- an event stream with its headers and then only an SSE comment every `--keepalive` seconds;
- a POST `/mcp` with the answer recorded for the same method, tool name and resource URI, carrying the caller's request id.

Then point `idle.py` at it with `--upstream-port <port>`.

## Comparing two TUI binaries

Run `idle.py` once per binary against the same frozen server with the same `--size`, `--idle` and `--steps`, into two output directories. Then compare:

```sh
python3 scripts/harness/tui/summary.py --reads "$OUT_A" "$OUT_B"
```

The header line of each directory shows the binary's SHA-256. Compare a screen only when `landed.ok` is true and its `top_rows` match in both runs, so both binaries were on the same screen.

## Safety

- The TUI starts a MASC server itself the first time nothing answers on its port. It runs the `masc` beside its own binary, or else the first `masc` on `PATH`. `idle.py` therefore runs a copy of `--tui` from a temporary directory and leaves out of the TUI's `PATH` every directory that holds a `masc`. If the relay stops answering, the TUI finds no server to start and only notes the manual command. Before the first TUI starts, `idle.py` also checks that `GET /health` through the relay answers 200, and it stops each TUI before it stops the relay.
- SIGINT (Ctrl-C), SIGTERM and SIGHUP (the terminal closing) end a run the same way. `idle.py` stops the TUI on screen, then the relay, puts the preferences file back and writes `idle.json` with `aborted`. A signal that arrives while a TUI starts, or while the run cleans up, waits until that step ends. A cleanup takes up to about 15 s: 5 s each for a TUI and a relay that ignore SIGTERM, and 5 s for a held preferences lock. The relay runs in its own session, so the terminal's signals reach only `idle.py`. It also stops by itself when `idle.py` exits. SIGKILL cannot be caught: the relay and the TUI still stop, but the preferences file stays as the TUI left it, `idle.json` lacks the last screen, and the copy of the TUI binary stays in the temporary directory (`masc-tui-idle-*`).
- The TUI gets only `HOME`, `PATH` (without `masc`, as above), `LANG` and `MASC_TOKEN` from the caller's environment, plus `TERM`, `COLORTERM` and `MASC_TUI_FRAME_TIMING`. A `MASC_HTTP_BASE_URL`, `MASC_BASE_PATH` or `MASC_CONFIG_DIR` in the caller's environment cannot send it past the relay or to another configuration.
- `v` on the Keeper list writes `<base-path>/.masc/config/tui-keepers.toml` directly. `idle.py` reads that file before the first TUI starts. When the run ends, it writes the file back with its mode if a TUI changed it, or removes it if a TUI created it. It does so under the lock the TUI takes on `tui-keepers.toml.lock`. A change anyone else made to the file during the run, such as a masc-tui of your own on the same workspace, is undone too. `idle.json` records the outcome in `preferences`; `lock-held` means the lock stayed taken for 5 s and the file was left as it was.
- Two more kinds of file under the base path are the TUI's own and stay after the run:
  - Each TUI writes its stderr to `<base-path>/.masc/logs/masc-tui-<pid>.log`, one file per screen. The `pid` of each screen in `idle.json` names its file.
  - When `MASC_TOKEN` is unset and the workspace has no stored masc-tui credential, or only an expired or mismatched one, the first TUI mints a new admin credential and stores it under `<base-path>/.masc/auth` (bin/masc_tui_credential.ml). This is local file work, so the relay cannot refuse it. Set `MASC_TOKEN` to run with a credential you choose instead.

## Output holds workspace data

Do not commit anything these tools write. All of it comes from the workspace:

- `idle.json`: screen rows, row samples and request paths;
- `relay.jsonl`: request paths with their queries, which carry Keeper, task and goal names;
- `<screen>.frame-timing.txt`: surface tags and the TUI's question rows with Keeper names;
- `<screen>.png`: the screen as drawn;
- the `--record` directory: the server's answers, bodies included;
- the frozen server's log.

Keep them in a directory outside the repository.

## Limits

- The frozen server answers only requests it has a recording for. A screen that asks for something new gets 404. A `/mcp` call is matched by method, tool name and resource URI only, so two calls with different arguments get the same answer.
- The observer stream on the frozen server sends no events. A replay measures time-only redraws, not the cost of events arriving. Measure that in front of a live server.
- CPU comes from `ps` and RSS from one `ps` reading when the window ends. On Linux, `ps` reports CPU time in whole seconds, so a short window there reads as 0 or 100%.
- The window is placed in the TUI's frame report by the time since the fork, so the exec delay is the error.
- The emulator reads rows of text. It knows the cursor addressing, erase, SGR and query answers the TUI's presenter uses. It does not implement scroll regions, insert or delete line, or autowrap.
- The relay speaks HTTP/1.1, answers each request on its own connection, and needs a request body to come with `Content-Length` and to be at most 1 MiB. A compressed event stream is counted in bytes, not events.
- After the first frame, `idle.py` waits up to 12 s for 2 s without output before it types a screen's keys. A screen that redraws at least every 2 s uses the whole 12 s.

## Self-test

```sh
python3 -m unittest scripts.tests.test_tui_frozen_server scripts.tests.test_tui_readonly_proxy \
  scripts.tests.test_tui_relay_log scripts.tests.test_tui_key_steps scripts.tests.test_tui_screen_steps \
  scripts.tests.test_tui_idle_landing scripts.tests.test_tui_vte_png
```

`test_tui_frozen_server` writes a small synthetic recording, starts `frozen_server.py` on a free loopback port and checks a plain answer, the 304 that keeps the `x-masc-*` header, a held event stream that sends only comments, and `/mcp` answers that carry the request id. `test_tui_readonly_proxy` starts the relay in front of a stand-in server that records what reaches it, and checks that writes get 403 and never reach it while a GET and a read tool do. `test_tui_relay_log` reads decision logs with a cut last line. `test_tui_key_steps` checks which keys may be pressed, the layout kind of drawn screens with cards, without cards and with stray glyphs, the shape of the per-key report, and that a key written to a pseudo-terminal whose child has exited reports `closed` instead of raising. `test_tui_screen_steps` checks that every step of the screen table stays inside the allow-list and that a move off its screen is refused. Checks that do not trust `MOVES` hold even when a move is added to it: no move sends `p w s x g U e y n`, Enter or a lone Esc (the one exception is `p` from Usage, a Navigate binding there), the Keeper screens take only Right, `[` and `]`, every destination is a whole `go` label the palette source offers, and every surface a place names is a `surface_key` some drawing in `bin/` passes. It also checks that step names are unique. `test_tui_idle_landing` reads synthetic frame reports for the surface on screen when the window starts, also after dropped frames, and checks that a screen on another surface fails and that the keys stop at the first that fails. `test_tui_vte_png` draws a reverse-video wide character and checks that its second half is drawn. It needs Pillow and a font with Hangul, and is skipped without them. None of these tests needs a MASC server or a TUI binary. CI does not run them.
