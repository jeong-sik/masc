# TUI UX stack #48234: before and after screens

Scope: layers 1 to 6 and 8 to 11 of the stack (#48231, #48232, #48233, #48250,
#48254, #48266, #48289, #48292, #48299, #48306). Layer 7 is the first version of
this document. Layers 6 and 8 to 11 were added to it by the layer that carries
this text.

## Source

Both sides are the `masc-tui` and `masc` binaries that the native TUI proof
workflow built on a macOS arm64 runner. Each artifact carries a `receipt.json`
whose `sha256` and `server_sha256` match the files that were run, and
`masc-tui --build-commit` prints the source commit below.

| Side | Source commit | Proof run | `masc-tui` sha256 | `masc` sha256 |
| --- | --- | --- | --- | --- |
| Before | `8478b73c5ed93bb3dc2af59a4d4f479f3711ffd5` (main) | 41875751621 | `57b3f6c019aac22f78a0eb9e9cb5590180f74f10921b9cf453305842446b2999` | `bbf78bbbbc852e1443b8fe10ccffbcdfc51cb3517580d9624cda72b7963a0e41` |
| After (layers 1 to 5) | `a8ac7782e3c4e76c80851efbdb2a7682be843076` | 41882548710 | `1d9b46b26ccbbaafb5b8e29303691a0b8d35996525067df74947fc066b97fa62` | `1a055097b60d66d1fcf1b768946af1a7d794c4ae1fd9c62c7283362cb49fd403` |
| After (layers 1 to 9) | `31d56f094eb2407c43a798fe28a655acb5bb5d41` | 41891144314 | `bc4ab5e3b3eceb61d592e41c7b36086d4933fc4f0dc37ef0fbb15c84f60108e2` | `121c5a7df6451a861c66d6ecdf29bc4aa2b76338c3b9bf7764afdea88c965644` |
| After (layers 1 to 10) | `cf512249ace0a8004473911ffd498e018e8ffd2b` | 41893673935 | `72b75b64133b8958647af57c81adc81c4d00dea267c81c11fc8a0b13da58b8dd` | `6ff4917f53ff0b47e3fb48a6f35b5e7a08f74206b6380f92f8345294cc5fd478` |
| After (layers 1 to 11) | `8969a8b26271b91b109849c96588c1f64d02f8ee` | 41895649701 | `15455664f4f711583f9e80554ed92c8234f2b09266aff89ca8a74b40124c7a5a` | `743b72a707f3eb76777b6ae6bf630b3dee1293727c9f1c3c132f1283c66329af` |

Commit `68231ced9d9` was added to layer 5 after the After build. It changes
`test/dune` only, so the After binary is the one the layer 5 head would build.

Every proof run ended `cancelled` or `failure`. In each, the
`test_workspace_file_confidentiality` suite failed one case (`Board startup
workspace authority`), the same case on main and on the stack (#48260). The
artifacts were uploaded after that failure.

## Environment

- macOS arm64 machine, one terminal per capture, driven through tmux at a fixed
  size. Sizes: 200x55, 120x35, 80x24, 320x50 and 400x50 for the footer
  comparisons, and 56x24, 68x24, 88x24 and 100x30 for the title rows of layer
  10. Screens opened with the command palette (`:`, then `go <name>`
  and Enter) are the ones with no key path from the Dashboard that the capture
  needed.
- Every process ran under `env -i` with `PATH`, `HOME` (an empty directory),
  `TERM=xterm-256color` and `LANG=en_US.UTF-8`. No credential, Keeper or
  workspace of the operator was read.
- A fresh workspace per side: `masc init`, `masc start --port <port>` from the
  same artifact as the TUI, an expiring bearer from `masc mcp-config --expiring`.
- The fixture is neutral text written through MCP: one Goal (`example-goal`),
  three Tasks, one Board post with one comment. `task-002` was claimed,
  started, and submitted for verification with a note and one evidence note.
  Three Keeper definitions (`imp`, `relay`, `scout`) are present but none can
  run on this machine, so every footer starts with `ACTION NEEDED 3`. Each
  side seeds its own fresh workspace, so timestamps differ between the sides.
- The key sequences are in the sections below. Each capture starts a new TUI
  process, waits for `HTTP [connected]`, settles for a few seconds, and then
  sends the keys. The capture driver is not part of the repository.

## Observed results

### Layer 1: Keepers header (#48231)

Keepers list at 120x35.

| Side | Header text | Header `AGE` right edge | Row `—` column |
| --- | --- | --- | --- |
| Before | `Mode…` | 61 | 59 |
| After | `Mode S` | 62 | 62 |

![Keepers header before](keepers-header-before.png)
![Keepers header after](keepers-header-after.png)

### Layer 2: `Left` closes a Task detail (#48232)

Work, `t` for Tasks, `Enter` for a detail, then `Left`.

- Before: the detail stays open. The screen still reads `MASC Task [task-002]`
  and the footer still offers `Left / Esc:back`.
- After: the Tasks list is on screen (`MASC Work / Tasks`) and the footer reads
  `j/k:select  t / Esc:Goals  Enter:detail  r:refresh  Tab:next  q:quit`.

### Layer 3: footers follow the open detail (#48233)

Work, `Enter` on the Goal. Footer at 200x55.

```
before  z:Candle  j/k:move  t:Goals / Tasks  Left / Esc:back  q:quit  …?
after   z:Candle  j/k:move  v:next Work tab  f:filter  Left / Esc:back  q:quit  …?
```

`t` toggles Goals and Tasks on the list only. With the footer no longer
spending a slot on it, two more keys fit.

At 400x50 no footer is cut. Goal detail, with the middle of the row left out:

```
before  z:Candle  j/k:move  t:Goals / Tasks  p:Approvals  v:next Work tab  …  Y:copy link  /:find  q:quit  …?
after   z:Candle  j/k:move  v:next Work tab  …  Y:copy link  Tab:next  q:quit  ?:help
```

`t`, `p` and `/` are gone from the open detail. `p` is Pause there, so
`p:Approvals` named the wrong action.

Board list at 400x50:

```
before  … v / V:up / down  c:reply  Y:copy link  …
after   … v / V:up / down  Y:copy link  …
```

The Board post footer keeps `c:reply` on both sides. At 200x55 the Board list
footer is the same before and after, because `c:reply` did not fit in either.
The Work Goals list, Tasks list and Task detail footers are the same before
and after at 400x50.

### Layer 4: search keys leave the detail footers (#48250)

System, `L` for the log list, `Enter` for a detail, at 320x50 so the footer is
not cut.

```
before  … Left / Esc:back  /:find  n / N:next / previous match  q:quit  1-16/16  …?
after   … Left / Esc:back  r:refresh  Tab:next  q:quit  ?:help  1-16/16
```

Work, `v` for Task Review, `Enter` for a detail. The footer fitter drops items
from the back, and at 320x50 it had already cut the Task Review detail footer
before `/:find` on both sides, so nothing differs there. At 400x50 it does:

```
before  … a / x:approve / reject  /:find  q:quit  …?
after   … a / x:approve / reject  r:refresh  q:quit  …?
```

The Task Review list footer is the same before and after at 320x50 and 400x50.

### Layer 5: Task history keeps its indentation (#48254)

Work, `t`, `j`, `Enter` on a Task. Before, the history heading, its status
rows, the event rows and the JSON all start at the left edge. After, the
heading sits in the column of the other headings, rows are indented under it,
and the JSON keeps its nesting. A wrapped line continues at its own indent.

![Task history before](task-history-before.png)
![Task history after](task-history-after.png)

### Layer 6: Goal detail headings and one row per Task (#48266)

Work, `Enter` on the Goal, at 200x55. Before is the layers 1 to 5 build, after
is the layers 1 to 9 build; no layer between them touches this screen.

- Before: the section headings and every field line are dim, and each linked
  Task takes three rows (`Task:`, `Title:`, `Link:`).
- After: the headings use the info colour and bold, the style the Log, Lane,
  Fusion and Config detail headings already use. Title, Goal, Stage, Next,
  Metric, Target, Due and Priority are drawn in the normal foreground. Created,
  Updated and Link stay dim. Each linked Task is one row:
  `task-001  todo · Example task A: draft the sample outline`.

![Goal detail before](goal-detail-before.png)
![Goal detail after](goal-detail-after.png)

### Layer 8: Keepers summary row (#48289)

Keepers list. The count items now lead and the layout and sort name trails; an
item that does not fit is left out whole.

```
80x24   before  compact · priority   ! 0 attention   ▶ 0 active   ◌ 0 waiting   ○ 0 inactiv…
80x24   after   ! 0 attention   ▶ 0 active   ◌ 0 waiting   ○ 0 inactive   ? 3 unknown
120x35  before  compact · priority   ! 0 attention   ▶ 0 active   ◌ 0 waiting   ○ 0 inactive   ? 3 unknown
120x35  after   ! 0 attention   ▶ 0 active   ◌ 0 waiting   ○ 0 inactive   ? 3 unknown   compact · priority
```

200x55 has the same order as 120x35. Before is the layers 1 to 5 build, after is
the layers 1 to 9 build.

![Keepers summary before, 80x24](keepers-summary-80-before.png)
![Keepers summary after, 80x24](keepers-summary-80-after.png)

### Layer 9: terminal title leads with the attention count (#48292)

Dashboard at 120x35. The window title is what tmux holds after the program sets
it with OSC 0 (`#{pane_title}`). The footer of the same screen starts with
`ACTION NEEDED 3`, because the three fixture Keepers cannot run.

```
before (main 8478b73c5ed)       connected · base
after  (layers 1 to 9)          (3) connected · base
```

The unit tests added in #48292 were not run: local Dune is blocked and the pull
request checks only run the type check.

### Layer 10: title rows at 80 columns (#48299)

Activity, Logs and the Features lane history, opened with `go Activity`,
`go Logs` and `go Librarian history` from the command palette. Before is the
layers 1 to 5 build at 80x24 and the layers 1 to 9 build at 120x35; after is
the layers 1 to 10 build. Clocks differ because each side seeds its own
workspace.

```
80x24   lane history  before  MASC Features · Librarian            (0 loaded / 0 retained · end)  HTTP [co…
80x24   lane history  after   MASC Features · Librarian (0 loaded / 0 retained · end)  HTTP [connected]
80x24   Logs          before  MASC Activity  (213 of 213)  seq 212  level≥DEBUG  03:58:04  Server  HTTP [c…
80x24   Logs          after   MASC Activity  (213 of 213)  seq 212  le…  04:16:19  Server  HTTP [connected]
80x24   Events        before  MASC Activity  ▸Even…  ·  (1 row · 4 events held)  03:58:06  HTTP [connected]
80x24   Events        after   MASC Activity  (1 row · 4 events held)  04:16:22  HTTP [connected]
120x35  lane history  before  MASC Features · Librarian            (0 loaded / 0 retained · end)  HTTP [connected]
120x35  lane history  after   MASC Features · Librarian (0 loaded / 0 retained · end)  HTTP [connected]
```

The same screens at the other widths, both sides built as above:

```
56x24   Events        before  MASC Activity  (1 row · 3 events held)  04:22:28  HT…
56x24   Events        after   MASC Activity  (1 row · …  04:23:09  HTTP [connected]
56x24   Logs          before  MASC Activity  (199 of 199)  seq 198  level≥DEBUG  0…
56x24   Logs          after   MASC Activity  (…  04:23:11  Server  HTTP [connected]
56x24   lane history  before  MASC Features · Librarian            (0 loaded / 0 r…
56x24   lane history  after   MASC Features · Librarian (0 loade…  HTTP [connected]
100x30  Logs          before  MASC Activity  ‹1  ▸L…  ·  (213 of 213)  seq 212  level≥DEBUG  04:23:00  Server  HTTP [connected]
100x30  Logs          after   MASC Activity  (213 of 213)  seq 212  level≥DEBUG  04:23:42  Server  HTTP [connected]
```

At 68x24 the rows read like the 56x24 ones with a longer reading. At 88x24 and
at 100x30 the Events row is the same before and after, with the strip drawn.
At 88x24 the Logs row is the same before and after, with no strip on either side.
At 120x35 the Logs and Events rows are the same before and after. At 80x24 the
`HITL Auto Judge` history reads `MASC Features · HITL…to Judge (0 loaded / 0
retained · end)  HTTP [connected]`: the name folds in the middle so the badge
stays whole.

![Activity Logs row before](activity-logs-80-before.png)
![Activity Logs row after](activity-logs-80-after.png)
![Activity Events row before](activity-events-80-before.png)
![Activity Events row after](activity-events-80-after.png)
![Lane history row before](lane-history-80-before.png)
![Lane history row after](lane-history-80-after.png)

### Layer 11: Approvals question heading (#48306)

Approvals at 120x35, opened with `go Approvals`. No question is waiting. Before
is the layers 1 to 10 build, after is the layers 1 to 11 build. The text of the
heading `[?] Questions waiting on you (0) · a:open answers` is the same on both
sides; the style is not.

- Before: bold and yellow (`ESC[1m ESC[93m`).
- After: no weight or colour code on the heading. `Theme.recede` draws the
  terminal's own foreground when the terminal has not reported its palette,
  which is the case under tmux here; on a terminal that reports it, the colour
  is blended toward the background. The `none -- nobody is waiting on a
  decision` row under it stays dim (`Ansi.dim`).

![Approvals question heading before](approvals-questions-before.png)
![Approvals question heading after](approvals-questions-after.png)

## Not verified

- Layer 11 with a waiting question, and on a terminal that reports its palette:
  the fixture has no question to ask, and the capture terminal does not answer
  the palette query, so neither the warning style nor the blended colour was
  drawn.
- Layer 10 at 200x55 and the Features lane history of lanes other than
  Librarian and HITL Auto Judge at 120x35.
- Layer 4, Harness detail and the Code draft keys: the fixture has no Harness
  verdicts and no repository, so neither screen was reached.
- Only the 120x35 Keepers list was measured for column positions. The 200x55
  and 80x24 Keepers screens differ in the same header text and were not measured.
- Screens come from the CI-built binaries on one macOS machine. Nothing here
  was run on Linux or in a terminal other than tmux.
