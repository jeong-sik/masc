# TUI idle measurement

These tools measure what each TUI screen costs while nobody presses a key. They serve the redraw rules of [the one-screen grammar RFC](../../../docs/rfc/RFC-tui-one-screen-grammar.md) (§8, §9 item 8) and the baseline of [the idle-TUI RFC](../../../docs/rfc/RFC-an-idle-tui-receives-only-changes-it-draws.md) (§7, §8 L0). Python 3.12 or later on macOS or Linux is required. Nothing here builds, starts or stops a MASC server.

| Tool | What it does |
|---|---|
| `readonly_proxy.py` | A loopback relay in front of a MASC server. It forwards reads and refuses writes, and logs every decision and every answer's bytes. |
| `frozen_server.py` | Replays what the relay recorded and never sends new data, so a TUI in front of it redraws only because time passes. |
| `idle.py` | Starts one TUI per screen through the relay, brings it to its screen and measures an idle window. |
| `summary.py` | Prints one line per screen, and with `--reads` what the TUI read in each window. |
| `vte.py`, `pty_driver.py` | The terminal emulator and the pseudo-terminal driver `idle.py` uses. |
| `relay_files.py` | The decision log and the recording format that the relay and the frozen server share. |

## The relay

`readonly_proxy.py` forwards GET and HEAD. It forwards a POST to `/mcp` only when every JSON-RPC message in it is a request for a read method (`initialize`, `ping`, the `*/list` methods, `resources/read`) or a `tools/call` of a tool in `READ_TOOLS`. `READ_TOOLS` lists tools that `lib/tool/tool_catalog.ml` registers as read-only. The relay answers 403 to everything else and does not forward it: other POSTs, PUT, PATCH, DELETE, websocket upgrades, JSON-RPC responses and bodies that name a member twice in one object (`json.loads` would judge the last `method` or tool name, while a server may run the first). A refused request shows in the log with its path and reason, so a run also shows which writes a screen tried. The TUI posts `/api/v1/tui/preferences` when it starts, and the relay refuses that, so a measured run leaves the server's stored TUI preferences as they were.

Each `done` line in the log is one answer: its path with the query, status, bytes and arrival time. An event stream also gets `progress` lines, about once a second, with its events and bytes so far per event name. Events are named by `scripts/harness/perf/tui_request_events.py`, the same parser [the TUI request probe](../perf/README-tui-requests.md) uses.

## Measuring screens

```sh
python3 scripts/harness/tui/idle.py \
  --tui "$MASC_TUI_BINARY" --base-path "$MASC_BASE_PATH" \
  --upstream-port "$SERVER_PORT" --out "$IDLE_OUT" \
  --idle 20 --steps overview,keepers
```

`--out` must be a new directory. Without `--steps`, all screens in the `STEPS` table of `idle.py` run in table order. A row of that table names a screen and the keys that reach it. Each screen starts a fresh TUI, so its keys start from the screen the TUI opens on: a command palette jump (`:go Work`), then single keys for that screen. The palette entries come from `bin/masc_tui_palette.ml` and the keys from `bin/masc_tui_keys.ml`. The Keeper list opens on the view `tui-keepers.toml` stores, so the table has no row per Keeper list view.

For each screen, `idle.json` records:

- `opened` (the first frame arrived), `keys` and `keys_ok` (each palette jump found the palette open), and `top_rows`, the first three screen rows when the window starts, which show where the keys landed;
- `window`: wall-clock start and end, the same span in nanoseconds since the TUI started, and whether the terminal closed during it;
- `idle`: PTY bytes and bursts in the window (a burst is output after at least 8 ms of silence), and the CPU percent that `ps` reports for the TUI;
- `rss_mb` when the window ends, and `row_changes`: the rows that changed most, with the first column that changed and the text there;
- `frames`: the frames the TUI recorded in the window through `MASC_TUI_FRAME_TIMING`, with build and present times, bytes presented and surface tags. The TUI keeps only its first 512 frames per phase. When the window reaches past them, `covered` is false and the counts are a lower bound;
- with `--probes N`, `key_latency_ms` for N Down and N Up presses, each timed from the write to the first byte back. A press is skipped while the screen is still drawing, and a press that draws nothing within 1 s is not counted;
- with `--png-font FONT` (needs Pillow), `<screen>.png`: the screen at the window start drawn with that font. Use a font that has the glyphs of the workspace's language.

```sh
python3 scripts/harness/tui/summary.py "$IDLE_OUT"
python3 scripts/harness/tui/summary.py --reads "$IDLE_OUT"
```

`--reads` adds, for each window, the requests that arrived in it by path, the requests the relay refused, and per event name the events and bytes of each event stream. Stream counts come from the relay's `progress` lines, so the span they cover can start and end up to a second away from the window. The rates divide by the span between the two lines, not by the window.

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

The header line of each directory shows the binary's SHA-256. Compare a screen only when its `top_rows` match in both runs, so both binaries were on the same screen.

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
- The relay speaks HTTP/1.1, answers each request on its own connection, and needs a request body to come with `Content-Length`. A compressed event stream is counted in bytes, not events.
- After the first frame, `idle.py` waits up to 12 s for 2 s without output before it types a screen's keys. A screen that redraws at least every 2 s uses the whole 12 s.

## Self-test

```sh
python3 -m unittest scripts.tests.test_tui_frozen_server scripts.tests.test_tui_readonly_proxy
```

`test_tui_frozen_server` writes a small synthetic recording, starts `frozen_server.py` on a free loopback port and checks a plain answer, the 304 that keeps the `x-masc-*` header, a held event stream that sends only comments, and `/mcp` answers that carry the request id. `test_tui_readonly_proxy` starts the relay in front of a stand-in server that records what reaches it, and checks that writes get 403 and never reach it while a GET and a read tool do. Neither needs a MASC server or a TUI binary. CI does not run them.
