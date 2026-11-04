# TUI frame cost and terminal output: prior art and what applies to masc

2026-11-04. Started from an operator report: holding Up or Down on the Keepers
surface stutters. This note records where the frame time went, what five other
terminal programs do, and which of their techniques fit masc. A proposal here
is not a decision.

## What a held arrow key cost on Keepers

Run: installed `masc-tui` (built 2026-11-04 10:12 from main), live workspace,
55 x 200 PTY, `scripts/tui-frame-latency.py --scenario keepers --keys 40
--gap 0.03`, Ghostty profile. Host load average 250 to 310 during the run, so
wall-clock numbers include CPU starvation. Evidence:
[before/](../evidence/tui-keeper-list-held-key-20261104/README.md).

| | frames | p50 | p95 | max |
|---|---|---|---|---|
| Build, keeper-list | 84 | 2.80 ms | 76.66 ms | 178.28 ms |
| Build, overview (same run) | 43 | 0.66 ms | 2.47 ms | 3.45 ms |
| Present, keeper-list | 84 | 0.08 ms | 2.28 ms | 37.15 ms |

- Present is not the cost. The Down phase wrote 55,208 bytes for 40 keys.
- More than 95% of keeper-list Build time fell outside the timed stages
  (`surface.*`). The stages cover framing, not the roster model.
- An 8 s `sample` of the TUI during a 150-key run put the UI thread off its
  poll in 1,569 of 2,232 samples. The top self frames were `List.exists`
  (192), a `Masc_tui_keeper_list_model` closure (160), `compare_val` (55),
  `caml_hash` (50), `List.find_opt` (39) and `caml_string_equal` (39). Under
  this load a runnable thread waiting for a core is sampled too, so these are
  shares of wall time, not CPU time.

Cause, read in source at `556b7739880`:

- `keeper_list_rows` joined every Keeper to six readings by scanning each list
  per Keeper. `holds_awaiting_verification` (added 2026-10-27, #46438) scanned
  every active task for every Keeper: 43 x 375 on the live workspace.
- `order_rows` worked out each row's activity twice per comparison.
- `selected_keeper` on Keepers rebuilds the whole ordered model. Per frame it is
  reached from the list itself, the terminal title, the Activity pane input,
  two footer notices and `reconcile_live_context`.

The earlier [extreme-performance study](extreme-performance-20261030.md)
rejected eager indexing of whole sources on synthetic inputs where every list
had the same length as the roster. The live shape is different: tasks
outnumber Keepers about nine to one, and the per-Keeper task scan is the
largest term. On that shape the indexed join returns the same rows, allocates
96,872 → 58,752 bytes per call, and runs 3 to 4 times faster at the median.
With it the UI thread went from saturated (off its poll in 94% of samples) to
66%, and the same 80 keys drew 109 to 151 frames instead of 73 to 108.
Numbers and limits are in the evidence bundle.

## What masc already has

- Alternate screen, DEC 2026 synchronized output, autowrap off during a frame
  (`bin/masc_tui_frame_presenter.ml`).
- Row-level diff: a changed row is `CSI row;1H`, `ESC[0m ESC[2K`, then the
  whole row.
- Input bursts coalesce: a frame waits until available input is drained
  (`bin/masc_tui_render_schedule.mli`, `take`).
- Bracketed paste, SGR mouse (`?1006;1000;1002h`), pane-scoped drag selection
  (`bin/masc_tui_pane_selection.mli`), OSC 52 copy (`Masc_tui_link.osc52_copy`),
  clipboard read for paste (`bin/masc_tui_clipboard.ml`).
- A frame-timing harness with per-stage records (`MASC_TUI_FRAME_TIMING`).

## Prior art

Sources were read at the commits named; nothing from them was built or run.
Claude Code is closed source and was read from a strings dump of the shipped
binary (v2.1.318), so its coordinates are code snippets, not lines.

| | Codex (`openai/codex` `0a944f8`) | Claude Code 2.1.318 | Kimi Code (`MoonshotAI/kimi-code` `444c609`, pi-tui) | Gemini CLI (`89e9d25`, Ink fork) | masc |
|---|---|---|---|---|---|
| Frame pacing | one deadline actor, 120 FPS cap (`tui/frame_requester.rs:96-125`, `frame_rate_limiter.rs`) | 16 ms; 4 ms for 50 ms after input; hold frames when >16 KB of stdout is queued, retry after 250 ms | 16 ms throttle; keyboard bypasses it (`tui.ts:1037-1088`) | 30 FPS throttle (`ink.js:92-99`) | drain input, then draw |
| Diff | cell diff, SGR deltas, one erase for a blank tail (`custom_terminal.rs:600-790`) | cell diff over packed 8-byte cells, cached SGR transitions, erase blank tails | row diff, `ESC[2K` + row | row diff; optional worker with line sync | row diff, `ESC[2K` + row |
| Scroll | DECSTBM only to push inline history (`insert_history.rs:168-218`) | DECSTBM + `CSI n S/T` when a scroll box moves; off under tmux, zellij, JetBrains, Windows Terminal | none | optional worker uses DECSTBM + IL/DL (`terminal-writer.js:552-667`) | none |
| Selection and copy | in-app selection in full-screen mode; native clipboard, OSC 52 fallback capped at 100 kB | in-app, copy on release; `pbcopy`/`wl-copy`/`xclip`, tmux buffer, OSC 52 over SSH; per-cell no-select and per-row soft-wrap flags | in-app in full-screen; native clipboard, OSC 52 fallback | F9 releases the mouse for native selection; OSC 52 under SSH/WSL, 100 KB cap | pane-scoped in-app selection; OSC 52 only |
| Long lists | anchor-based render, LRU of wrapped layouts (64 entries, 8 MiB) | renders visible messages only | per-component line caches | virtualized list with measured heights | per surface; Keepers rebuilds every row each frame |

Antigravity CLI (`agy`) is a closed-source TUI with an inline mode and copy on
select per its codelab; its renderer could not be confirmed.

[wterm](https://github.com/vercel-labs/wterm) (`0dcaca9`) is a browser
terminal, not an agent TUI, but it shows what an emulator rewards:

- A row erased with `ESC[2K` (or `ED`) gets a new row id and is rebuilt as a
  new row; `EL 0` keeps the id (`src/grid.zig:154-162`,
  `src/terminal.zig:1241-1287`).
- Scrolled rows keep their ids and their DOM nodes move instead of being
  rebuilt (`packages/@wterm/dom/src/renderer.ts:1306-1340`).
- Cost grows with style changes per row, since each change starts a new span.
- A frame held in mode 2026 is painted anyway after 1 s.

Published numbers are scarce. A Claude Code engineer gave a 16 ms frame budget
and about 5 ms from scene graph to ANSI, and moved to packed typed arrays to cut
GC pauses (https://news.ycombinator.com/item?id=46699072). No other project
published timings.

## What applies to masc, in order

1. **Frame preparation first.** It is where the measured time is. After the
   roster fix, measure the other surfaces the same way; the stage timers only
   cover framing, so add a stage around each surface's model work before
   judging it.
2. **Build spikes.** Keeper-list Builds of 76 to 178 ms sat outside every stage.
   They could be GC pauses or the host's load. OCaml runtime events record GC
   phases with timestamps; read them against the frame records before changing
   allocation.
3. **Presenter cell diff.** Parse each changed row into cells and write only the
   changed runs, with SGR deltas and `EL 0` for a blank tail. Side-by-side
   panes then stop rewriting each other's cells, and emulators like wterm keep
   the row. It does not shorten local Present, which is already 0.08 ms; it is
   for SSH, tmux and web mirrors. Measure bytes per frame before and after.
4. **Stdout backpressure.** Present flushes on the UI thread; the run above
   blocked 37 ms in one flush. Writing on another thread with latest-frame-wins,
   or holding frames while output is backed up as Claude Code does, keeps keys
   moving when the terminal is slow.
5. **Copy.** Try the native clipboard first (`pbcopy`, `wl-copy`, `xclip`) and
   fall back to OSC 52, as Codex, Claude Code and Gemini CLI do. Join
   soft-wrapped rows and leave gutters out of a copy.
6. **Scroll regions.** Most masc frames put panes side by side, so a whole-row
   shift is rare and left/right margins (DECSLRM) are not widely supported.
   Claude Code gates its path behind a flag and a terminal list. Lowest priority.
7. **wterm for evidence.** `@wterm/core` runs headless in Node and can replay
   recorded PTY bytes into a cell grid (`terminal-core.ts:168-238`). It could
   replace the ttyd + Chromium step in `scripts/capture-tui-screenshots.py` for
   text captures. The built-in core has no reflow and no OSC 52.
