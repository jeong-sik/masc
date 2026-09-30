# TUI region baseline before G0 — 2026-09-28

The workbench RFC's region steps (`docs/rfc/RFC-tui-operator-workbench.md`
§5.9, G0 to G5) change how many rows the frame spends on itself. G0 makes
every reader of that count read one value from `Masc_tui_frame`. §5.9 asks for
a measured baseline, with fake Keeper and Board data, before G0. This
directory is that baseline for the first group of readers. It was measured in
CI, not with a local build.

## Every reader, and the screen that measures it

The readers are the lines the RFC's count command finds on `main`
(`80231d4c56`): `rg -n 'framed_chrome_rows|framed_content_height|Masc_tui_frame\.chrome_rows' bin/masc_tui_*.ml | rg -v 'let framed_'`
prints 15 lines, one of them a comment. `chat_history_first_row` is the chat's
mouse row base, which G0 also moves onto the frame's value.

| Reader | Where | Screen | Suite |
|---|---|---|---|
| `surface_chrome_rows` | `render_prim.ml:1277` | Board list and Config, both laid out by `surface_chrome` | this one |
| `keeper_roster_pane` | `render_prim.ml:1572` | roster beside the keeper detail and beside the chat | this one |
| `keeper_detail_pane` | `render.ml:8503` | keeper detail without the roster (unframed) and with it (framed) | this one |
| `chat_history_first_row` | `render_chat.ml:3055` | chat, pinned by a press on a folded Gate argument row | this one |
| `write_list_sidebar_selection` | `render_prim.ml:1676` | task detail sidebar | C |
| `memory_overview_scrolled` | `types.ml:9457` | Memory overview | C |
| `memory_overview_rows`, `render_memory_body` | `render_memory.ml:934`, `:1044` | Memory overview | C |
| `keeper_runtime_picker_page` | `types.ml:10463` | runtime picker | B |
| `lane_run_chrome_rows*` | `render.ml:6986` | Lane run detail | C |
| `verification_detail_pane` | `render.ml:9480` | Verification detail | C |
| `pane_surface_content_height` | `render.ml:13835` | Code, Resources | C |
| `context_inspector_detail_viewport` | `render.ml:16547` | context inspector | B |
| `overlay_window_height` | `render.ml:16698` | help, keeper deletions, agenda overlays | B |
| `answering_viewport` | `render.ml:17058` | answering overlay | B |

The Keepers list reads none of these. It counts the rows it drew
(`render_keepers`: `count_frame_lines` plus its three footer rows). This suite
measures it as the control: a body the frame lays out without the count.

Five screens subtract the same count as a literal and do not match the
command: Approval detail and Schedule detail (`rows - 6`), Log detail and
Harness detail (`rows - 5`), and the runtime.toml status (`- 5`). They go with
G0 and are measured in C.

B (overlays and the runtime picker) and C (the remaining detail screens) are
separate suites that follow this one.

## How it was measured

- Suite: `test/test_tui_region_baseline_pty.py`, alias
  `runtest-test_tui_region_baseline_pty` in
  `test/stanzas/test_tui_region_baseline_pty.inc`. It is not part of the
  default keyboard walk.
- Shared helpers: `test/tui_region_harness.py`, which the B and C suites
  import. A screen is read only when all of these hold:
  - the terminal has been silent for a quarter second and its last bytes
    close a frame;
  - every one of the 30 rows was written since the last full redraw;
  - every request the TUI made was answered by a fixture;
  - no row shows the harness's 503 text, or the frame's `+N rows not shown`
    note.
- Data: keepers `alpha` and `beta`, four Board posts, a runtime.toml, and one
  chat history row holding a Gate argument long enough to fold. Every other
  read is answered with its empty reading. The live feed's stream stays open
  by writing a comment every second.
- Terminal: 30 rows, at 80, 100, 109, 110, 157 and 158 columns.
  - 80 and 100 are common terminals.
  - 109 and 110 sit either side of the edge where the roster and the framed
    detail open (110).
  - 157 and 158 sit either side of the edge where the Activity pane opens
    (158).
  - The roster is measured at 110 and 157. It is not drawn at 158.
- Rows are found by structure:
  - Row 1 is the tab strip. Row 2 is the body's top: blank, or a box's top
    border. The title is the body's first drawn row below that.
  - The key hints are the body's last row, right above the composer. They
    must hold text and no box glyph; a pane that outgrew its rows pushes its
    border onto them. The chat draws its own input and has no composer row.
  - Rules are rows holding a run of box glyphs. A framed pane's bottom border
    holds its bottom corner. `last` is the last drawn row above the key hints.
  - The body is cut at the roster (34 cells) and the Activity pane (56 cells).
    Each cut is checked against the pane's border glyph. The roster's own top
    and bottom borders are measured in its cells.
  - A list window such as `1-22/37` is the reader's computed height, as the
    screen prints it. Config also pins the number of the source line its body
    ends on.

## What it measured

On every screen here: title row 3, key hints on row 29 (row 30 on the chat).
Numbers that move with the width are called out.

| Screen | Body top | Rules | Bottom border | Last drawn row | Blank rows | Also |
|---|---|---|---|---|---|---|
| Keepers list (control) | blank | 4, 7, 28 | — | 28 | 17 | |
| Board list | blank | 4, 7, 9 | — | 13 | 15 | |
| Config (runtime.toml) | blank | 4, 9 | — | 27 | 1 | ends on source line 18 |
| Keeper detail | blank | 4 | — | 27 | 7 | window `1-22/37` |
| Keeper detail beside the roster | border | 4, 28 | 28 | 28 | 0 | window `1-22/37`; roster rows 2–28 |
| Keeper chat beside the roster | blank | 4, 26 | — | 29 | 19 | roster rows 2–27 |
| Keeper chat | blank | 4, 26 | — | 29 | 19 (20 at 157) | |

At 157 the folded Gate argument fits one row instead of two, so the chat has
one more blank row.

In the chat at 100 columns the folded Gate argument's first row is row 6. A
press is followed by typed input, which the TUI draws only after handling the
press. After presses on rows 5 and 7, the chat still reads `tools:results`,
shows no tail of the argument and has read no file changes. After a press on
row 6 it reads `tools:full`, shows the tail and reads the keeper's file
changes.

## Runs

- Passing run: Test workflow run
  [36431311636](https://github.com/jeong-sik/masc/actions/runs/36431311636) on
  `4f174c5bdb4491164b0629d99ef89bcf5f2a6dd0`: `region baseline: PASS` in 47
  seconds, dispatched with

  ```sh
  gh workflow run test.yml --ref test/tui-region-baseline \
    -f suite=test_tui_region_baseline_pty
  ```

- The expected numbers were measured deliberately before that. Run
  [36426485595](https://github.com/jeong-sik/masc/actions/runs/36426485595)
  printed them with nothing expected and failed by design. The fields added
  since then (last drawn row, roster borders, Config's source line) were
  measured by replaying the screens of run
  [36427566813](https://github.com/jeong-sik/masc/actions/runs/36427566813)
  through the helpers. The passing run then confirmed them against the TUI.

## The screens

`screens/` holds every measured screen of the passing run:

- `<screen>-<cols>x30.ansi`: the bytes since its last full redraw;
- `<screen>-<cols>x30.txt`: the text a terminal shows.

It also holds a picture of five of them: `keepers-80x30.png`,
`config-158x30.png`, `keeper-detail-roster-110x30.png`,
`keeper-chat-roster-110x30.png` and `keeper-chat-157x30.png`.

`render_screens.py` rebuilds them. It needs `pyte` and `Pillow`. The pictures
were drawn with D2Coding Ligature Nerd Font Mono (Regular and Bold), which has
Hangul and the box glyphs.

```sh
# From the committed bytes; the CI artifact expires on 2026-10-12.
python3 render_screens.py ansi screens --png keepers-80x30 \
  --font D2CodingLigatureNerdFontMono-Regular.ttf \
  --bold-font D2CodingLigatureNerdFontMono-Bold.ttf

# From a run's log.
gh run download 36431311636 -R jeong-sik/masc -n suite-runner-log -D log
python3 render_screens.py log log/ci-run-tests.log screens
```

Colours approximate a dark theme. Cell positions and widths are the TUI's own.

## Refresh after Keeper portraits — 2026-09-29

The original `screens/` and the table above preserve the pre-portrait
measurement. The current expectation adds the intentional portrait from
[#39750](https://github.com/jeong-sik/masc/pull/39750), commit
`b7554bdf66`: `keeper_detail_pane` places the three Identity rows beside
`Masc_tui_keeper_portrait.mosaic_band`, whose height is twelve rows. Its
`beside` function keeps the longer side, adding nine content rows.
The suite names `masc_tui_keeper_portrait.ml` and its interface in
`SOURCE_MODULES` so a change to that geometry selects this baseline too.

[PR run 36511020916, job 109222918530](https://github.com/jeong-sik/masc/actions/runs/36511020916/job/109222918530)
on `b8be620e162c08a74252ae0017729758634450bf` captured all 34 screens before
rejecting the old expectation. `portrait-refresh/` contains the eight affected
ANSI frames decoded from that job's existing zlib/base64 log records. These
are captures from the failed run, not a new native run or generated screenshots.

| Screen | Widths | Old content | Current content | Geometry retained |
|---|---|---|---|---|
| Keeper detail | 80, 100, 109, 110, 157, 158 | 7 blank rows; `1-22/37` | 4 blank rows; `1-22/46` | title 3, rule 4, last 27, hints 29, composer 30 |
| Keeper detail with roster | 110, 157 | `1-22/37` | `1-22/46` | borders 2–28, title 3, rules 4/28, last 28, no blank rows, hints 29 |

The recorded first screen now draws the portrait at rows 5–16, Current
failure at 18–19, Board attention at 21–22 and Gate at 24–26. The scroll
viewport still shows 22 rows; only the content length and visible blank-row
count changed. Replaying all 34 frames through the existing structural
helpers gives the unchanged values for every other screen. The recorded
chat press row remains 6, and its click assertions run before `check_all`.

The later HTTP-handler error is teardown after that expectation failure:
the exception leaves `test_http_endpoint` while the TUI still holds the
observer stream, and `run_terminal_scenario` kills the process in its outer
`finally`. The fixture cleanup check is retained. Geometry, missing-frame,
unanswered-read, clipping and click assertions are unchanged. A new CI run
must confirm the updated expectation and normal shutdown together.


## Chat portrait and displaced composer — 2026-09-29

[PR #39883 run 36529156143, job 109278685601](https://github.com/jeong-sik/masc/actions/runs/36529156143/job/109278685601)
on `05dc861f1584fa64a102cd63dee0c5bc56c965b3` captured the two frames in
`chat-portrait-failure/`. They were decoded from the job's existing
zlib/base64 log records; these are **before-fix failure evidence**, not a
successful rerun. The original `screens/` captures remain unchanged.

Replaying both sets through `tui_region_harness.whole_screen` and slicing
cells 34 through the terminal width shows exactly one changed chat row at
both 110 and 157 columns:

| Row | Original right pane | Failed PR right pane |
|---|---|---|
| 27 | `    >` | empty |

The failed frame instead draws `>` at column 5, in the left pane, while the
original draws it at column 39. Gate argument rows 6–7 and all other right
pane rows are byte-equivalent after trailing spaces are removed. These
frames use a mosaic, so PNG placement cannot be the cause.

The portrait's final spacer called `Masc_tui_ansi.box_bottom`, which emits
only a newline for an unframed full-screen surface. `write_two_panes` pads
an exhausted left pane, but joins a present empty line at its actual zero
width. That moved the corresponding right-hand composer left by 34 cells.
The fix draws the spacer with `box_line ... ""`, preserving the pane width.
The portrait PTY now checks the composer's cell column in split chat,
including mosaic, pixel, resized and colour-disabled layouts.

Only the left roster's bottom changes intentionally, from row 27 to 13,
leaving room for the conversation caption and portrait. The expected right
pane blank count remains **19**, not the broken frame's 20. A focused CI
rerun must verify the corrected frame and successful fixture shutdown;
these captured frames do not establish either result.
