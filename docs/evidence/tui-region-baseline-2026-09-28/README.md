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
| `surface_chrome_rows` | `render_prim.ml:1277` | Keepers list, Board list, Config (`config_heading_rows`) | this one |
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
  - no row shows the harness's 503 text or "feed closed".
- Data: keepers `alpha` and `beta`, four Board posts, a runtime.toml, and one
  chat history row holding a Gate argument long enough to fold. Every other
  read is answered with its empty reading, and the live feed's stream stays
  open.
- Terminal: 30 rows. Widths 80 and 100 are common terminals. 109 and 110 sit
  either side of the roster and the framed detail (110). 157 and 158 sit either
  side of the Activity pane (158). 176 is where the pane's wide layout fits.
  The roster is measured at 110 and 157. It is not drawn at 158: discovery
  run 36423698174 waited for it there and timed out.
- Rows are found by structure:
  - Row 1 is the tab strip. Row 2 is the body's top: blank, or a box's top
    border. The title is the body's first drawn row below that.
  - Rules are rows holding a run of box glyphs. A framed pane's bottom border
    holds its bottom corner.
  - The body is cut at the roster (34 cells) and the Activity pane (56 cells),
    and each cut is checked against the pane's border glyph.
  - The footer is the last row drawn above the composer. The chat draws its
    own input and has no composer row.
  - A list window such as `1-22/37` is the reader's computed height, as the
    screen prints it.

## Runs

- Measuring run: Test workflow run
  [36426485595](https://github.com/jeong-sik/masc/actions/runs/36426485595) on
  `e79042d83cddf1a26ab190795aa6ef5e13840461`. It ran with nothing expected, to
  print what the screens measure. It fails by design.
- Passing run: Test workflow run
  [36427566813](https://github.com/jeong-sik/masc/actions/runs/36427566813) on
  `0e9eef707897c8ddef036c110adad3d0ab209657`, with the numbers below
  expected: `region baseline: PASS` in 42 seconds.
- Both were dispatched with

  ```sh
  gh workflow run test.yml --ref test/tui-region-baseline \
    -f suite=test_tui_region_baseline_pty
  ```

## What it measured

Title row 3 and footer row 29 (row 30 on the chat), at every width measured.
A number that moves with the width is called out.

| Screen | Body top | Rules | Bottom border | Blank rows | Window |
|---|---|---|---|---|---|
| Keepers list | blank | 4, 7, 28 | — | 17 | — |
| Board list | blank | 4, 7, 9 | — | 15 | — |
| Config (runtime.toml) | blank | 4, 9 | — | 1 | — |
| Keeper detail | blank | 4 | — | 7 | `1-22/37` |
| Keeper detail beside the roster | border | 4, 28 | 28 | 0 | `1-22/37` |
| Keeper chat, with and without the roster | blank | 4, 26 | — | 19 (20 at 157) | — |

At 157 the folded Gate argument fits one row instead of two, so the chat has
one more blank row. In the chat at 100 columns the folded Gate row is row 6.
A press on row 6 unfolds it; a press on row 5 or row 7 does not.

## The screens

`screens/` holds, for each measured screen of the passing run:

- `<screen>-<cols>x30.ansi`: the bytes since its last full redraw;
- `<screen>-<cols>x30.txt`: the text a terminal shows;
- `<screen>-<cols>x30.png`: a picture rendered from the `.ansi` with pyte.

`render_screens.py` rebuilds all three from a run's `suite-runner-log`
artifact:

```sh
gh run download 36427566813 -R jeong-sik/masc -n suite-runner-log -D log
python3 render_screens.py log/ci-run-tests.log screens \
  --font D2CodingLigatureNerdFontMono-Regular.ttf \
  --bold-font D2CodingLigatureNerdFontMono-Bold.ttf
```

It needs `pyte` and `Pillow`. Colours approximate a dark theme; cell
positions and widths are the TUI's own.
