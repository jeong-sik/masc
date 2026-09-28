# TUI region baseline before G0 — 2026-09-28

The workbench RFC's region steps (`docs/rfc/RFC-tui-operator-workbench.md`
§5.9, G0 to G5) move rows. Its §5.9 asks for a measured baseline with fake
Keeper and Board data before G0. This is that baseline. It was measured in
CI, not from a local build.

## How it was measured

- Suite: `test/test_tui_region_baseline_pty.py`, alias
  `runtest-test_tui_region_baseline_pty` in `test/dune`. It is not part of the
  default keyboard walk.
- Data: the keyboard harness's fixtures from `board_reference_http_fixtures()`,
  keepers `alpha` and `beta` and four Board posts, served by
  `test_tui_keyboard_input.run_terminal_scenario`.
- Terminal: 30 rows, at 80, 100, 131, 132 and 140 columns. No Activity pane is
  drawn at these widths; it opens at 158.
- Run: Test workflow run
  [36414157831](https://github.com/jeong-sik/masc/actions/runs/36414157831)
  on `214fd9c212963e8c57cc8866a58db07fd40bdcfe`, dispatched with

  ```sh
  gh workflow run test.yml --ref test/tui-region-baseline \
    -f suite=test_tui_region_baseline_pty
  ```

  The suite runner log is that run's `suite-runner-log` artifact. The pull
  request that adds this directory runs the same suite again against the
  numbers below.

## What it measured

Rows are the terminal's, counted from 1. Row 1 is the tab strip, row 2 the
frame's top row, row 3 the title and row 4 its divider. The footer is the row
with the key hints, which end in the help key `…?`. On three surfaces it is
row 29 and the composer takes row 30; the chat draws its own input and puts
its hints on row 30. No number changed with the width.

| Surface | Title row | First row under the title | Footer row | Blank rows between |
|---|---|---|---|---|
| Keepers list | 3 | 4 | 29 | 16 |
| Keeper `alpha` detail (`▸Info`) | 3 | 4 | 29 | 7 |
| Keeper `alpha` chat | 3 | 4 | 30 | 18 |
| Board list, four posts | 3 | 4 | 29 | 15 |

The blank rows are what each surface's fixture leaves unfilled, so they are
the rows a step that adds or removes chrome moves.

Not measured here: the Lane run detail and Memory, which also read the frame's
row count.

## Reading the screens

The suite prints each measured screen's bytes since its last full redraw,
zlib-compressed and base64-encoded, between
`=== region-baseline <surface> <cols>x30 begin ===` and `... end ===`.
To rebuild one as text:

```python
import base64, re, zlib
import pyte

log = open("ci-run-tests.log", encoding="utf-8").read()
body = re.search(
    r"=== region-baseline keepers 80x30 begin ===\n(.*?)\n=== region-baseline",
    log, re.S).group(1)
raw = zlib.decompress(base64.b64decode("".join(body.split())))
screen = pyte.Screen(80, 30)
pyte.ByteStream(screen).feed(raw)
print("\n".join(screen.display))
```

The `pyte` screen needs the width the frame was measured at, the `<cols>` in
its marker.
