# Keepers list: failed-attempt glyph and last-failure colour (RFC-0503 L4)

- 날짜(ISO8601): 2026-11-07T15:40:00+09:00
- 작성자: Claude (session of the masc-pro-builder git identity)
- 결정 ID: rfc-0503-l4-49624
- 적용 대상: PR #49624 (RFC-0503 L4). Captured on the PR head `9477c0a7491506848d1128179640f91021e084d5` against its base `5ee68a28c40056863f816f536a801d2268da675f`. See "Heads" for the restack that moved the PR head afterwards
- 결정 상태: 추적 필요 (evidence for review; the merge decision is the owner's)

## 근거 (Evidence)

- 항목: before/after captures of the TUI Keepers tab at 80×24, 120×35 and 200×45, with colour and with `NO_COLOR=1`, in the compact, detailed and grouped layouts, over 15 synthetic keepers
- 출처: two macOS arm64 proof builds of `masc-tui` made by `pr-check.yml` → `tui-native-proof.yml`, driven in tmux 3.6a against a synthetic HTTP server
- 확인일시: 2026-11-07T14:46:00+09:00–2026-11-07T15:35:00+09:00
- 신뢰도: High for what the two identified binaries draw on this synthetic input. Not a measurement of live data or of other terminals
- 제한조건: see "불확실성"

### Heads

| | source | proof run | `masc-tui` SHA-256 |
|---|---|---|---|
| before | `5ee68a28c40056863f816f536a801d2268da675f` (main when the PR was opened) | 42341952949 | `7cc162ab1250891b43308138deff1d75724dca58db7fb60f1e5d6def2673bec5` |
| after | `9477c0a7491506848d1128179640f91021e084d5` (PR head when captured) | 42343259996 | `6eba6699e30b53af597e06472ffee2b0be2d3c07b5322b8458a2d3458e269eae` |

`receipt-before.json` and `receipt-after.json` are the unmodified receipts of those runs. Both say `visible_ui_verified: false`; the captures here are the first look at the screen. In a receipt, `source_sha` is the commit that was built and `workflow_sha` is the commit of the workflow definition the run executed. They are equal for the before run. For the after run `workflow_sha` is main `690d1ef4eaf691c5f99b3fc6bc69ea426c302bc2`, which is also the `headSha` that `gh run view` prints for that run; the binary was built from `source_sha`.

The PR branch was restacked after the captures: head `82ca2bbd45631b1e8473913396f6f1a438945cee` on main `bea9d884b0c5` (force push 2026-11-07T06:14:11Z by the PR owner). `git range-diff 5ee68a28c40..9477c0a7491 bea9d884b0c..82ca2bbd456` reports the second and third commit as identical and the first commit as changed only in the context lines of `bin/masc_tui_render_keepers.ml`. Main itself changed that file between the two bases (101 insertions, 13 deletions, including a `keeper_path_rest_detail` item in the DETAIL text); those changes are not in either capture build. The restacked head was not built for capture. The PR was squash-merged into main as `69d4c9c84c7` on 2026-11-07T06:46:23Z; `git diff --stat` shows the same 7 files and line counts for the squash commit and for head `82ca2bbd456`.

### Input

Fifteen synthetic keepers, one per state the list has to tell apart: `held-call` (approval pending), `question`, `try-failed` (an attempt of the open turn failed), seven failing keepers whose last-failure sentence has a different source (`recovery` = recovery needed, `rate-limit` = rate limited over 3 candidates, `new-turn` = provider over 1 candidate while streaming, `no-receipt`, `fenced` = effect fenced over 2 candidates, `no-terminal` = terminal not observed, `heartbeat`), `running`, `model-wait`, `idle`, `paused`, `offline`. Names, runtime ids, messages and times are invented. The wire shape of each endpoint (`/api/v1/gate/keepers`, `/api/v1/keepers/turns`, tool approvals, asks, health, preferences) was copied from a recorded response of a live server and every name, id, text and time was replaced; the recording is not retained. The roster's evidence items carry the summary text that the decoder recomputes from the failure (`keeper_runtime_walk_evidence.ml`, `with_summary`), so every row is read as typed evidence and none as "historical evidence unreadable".

The offline row is not paused: the recorded offline row was paused, which the list draws as `Ⅱ paused`.

### Commands

Each session, per build, size and colour mode (`NO_COLOR=1` or unset):

```
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=<empty dir> TERM=xterm-256color LANG=en_US.UTF-8 [NO_COLOR=1] \
  masc-tui --base-path <synthetic workspace> --port <synthetic server>
wait for "HTTP [connected|partial]"; answer the colour queries; settle
key 3        # Keepers tab; capture
key v        # next layout; capture
key v        # next layout; capture
```

tmux started with `COLORTERM=truecolor`. The tool renders the `.ansi` capture to PNG with its own 16-colour palette, Menlo with Apple fallback fonts (Pillow 12.1.1), on macOS 27.2. The layout the tab starts in differs between sessions, so each session visits all three with two `v` presses and names the files by the layout label on the summary line (at 80 columns the label is cut off, so by the shape of the screen). A session whose first screen shows a failed read is run again. The driver, the synthetic server and the renderer are scratch tools and are not retained: the server depends on the private recording.

Not retained: every 120×35 capture, the grouped layout at every size, and every other combination of size, layout and colour mode that is not listed below. Their numbers exist only in `counts.txt`, and the statements below about 120 columns, the grouped layout and the 18 `NO_COLOR=1` captures rest on those numbers and on the unretained `.ansi` files, not on a retained image.

Retained files: `{before,after}-{200x45-compact-color, 200x45-detailed-color, 80x24-compact-color, 200x45-compact-nocolor}.png` and the matching `.ansi.gz` (the unmodified tmux capture with escape codes, gzip), `colour-spans.txt` (style of chosen rows decoded from the `.ansi` captures), `counts.txt` (the counts below for every size and colour mode).

## 검증 (Verification)

What changed on screen (`colour-spans.txt`). In these captures `Theme.bad` came out as SGR 91, `Theme.warn` as 93 and `Theme.recede` as 38;5;245; `recede` is projected from the palette the terminal reports, so that number depends on the session:

| cell | before | after |
|---|---|---|
| `held-call` NOW | `! held call` in 91 | unchanged |
| `question` NOW | `? question` in 93 | unchanged |
| `try-failed` NOW | `! try failed` in 91 | `✗ try failed` in 93 |
| failing row, `◂ …` sentence, DETAIL cell (`200x45-compact-color`; compact and grouped layouts, detailed below 120 columns) | the whole DETAIL in 245 | the sentence in 93, the rest (`· task …`) in 245 |
| failing row, `◂ …` sentence, RUNTIME cell (`200x45-detailed-color`) | 245 | the whole cell in 93 |

- Without colour, `before-200x45-compact-nocolor.png` shows `! held call` and `! try failed`: the same glyph, told apart by the words only. `after-200x45-compact-nocolor.png` shows `!` and `✗`. The list pane of the 18 `NO_COLOR=1` captures (2 builds × 3 sizes × 3 layouts) holds no foreground-colour escape code; this was counted on the `.ansi` files, of which only the 200×45 compact captures are retained here.
- Widths do not change. `counts.txt` gives the same numbers for both builds at every size: rows drawn, summary items kept, failing rows with a whole cause word, failing rows with the age visible, and the position of the Mode column. In particular the `✗` row keeps the Mode letter in the same column as the `!` rows. U+2717 and U+25C2 are East Asian Width "N" (one cell whatever the terminal's ambiguous-width setting); the glyphs already in the NOW column `○` `×` `Ⅱ` are "A".
- 120 and 200 columns: the summary line keeps all six items and the layout label; the cause word is whole in 7 of 7 failing rows and the age in 7 of 7.
- 80 columns (`80x24-compact-color`): the summary line keeps 5 of 6 items and drops `? 0 unknown` and the layout label `compact · priority`. The cause word is whole in 3 of 7 failing rows (`provider`, `heartbeat`); in the other four it is cut inside the word (`recovery ne…`, `rate limite…`, `effect fenc…`, `terminal no…`). The age is whole in 7 of 7. Same in both builds: not changed by this PR.
- AGE and `◂ <age>` sit side by side in idle failing rows and differ by 0 to 1 second in the captures (`2m14s ◂ 2m15s`). In these captures both come from one synthetic timestamp, so how often they differ in live data is not measured here. At 80 columns the DETAIL cell is 22 cells wide and the prefix `◂ 2m14s · ` takes 10 of them before the cause word starts.
- `o` cycles the order `priority → recent → oldest → activity → name` and starts at `priority` (summary line label, checked on the after build).
- `Enter` on a failing row opens the detail page: `Suggested action: probe` is near the top and the section "Recorded Runtime Walk" is section 5 of the page.

Operator questions, keys pressed from the Keepers tab (after build; before is the same except for the colour and glyph rows):

| question | keys |
|---|---|
| failing now, or did the last turn fail | 0. `◂ …` marks a failing keeper, `✗ try failed` an open turn whose attempt failed, `! held call` a human decision; the three marks differ without colour |
| what is it doing now | 0. NOW shows `> streaming` for the failing `new-turn` and `○ idle` for the other failing rows |
| when did the last turn end | 0 at all three widths (age whole in 7 of 7 failing rows) |
| why did it end | 0 at 120 and 200 columns (cause word whole 7 of 7); 4 of 7 rows cut mid-word at 80 columns; the values are in the detail page (`Enter`, section 5) |
| is there a next step | not in the list (no `▸` yet); `Enter` shows `Suggested action` |
| does a human have to act | 0. `! 2 attention` counts `held-call` and `question`; the failing rows are counted under `◂ 8 failing`, which includes `try-failed` |

## 불확실성 (Uncertainty)

- 미확인 항목: live data (the earlier live read had 15 of 15 failing keepers with the cause word `provider`; the synthetic rows mix causes on purpose, so this bundle says nothing about how often words repeat), other terminals and fonts, the palette of a real terminal (the PNG palette is the tool's own; SGR 91 and 93 are palette entries, not fixed colours), the restacked head `82ca2bbd456` as a built binary
- 영향: the captures establish the glyph, colour, width and legend behaviour of the two identified builds on this input; they do not establish contrast on any real palette
- 추가 확인 필요: how `✗` draws in the terminals the owner uses; whether the cause word should survive at 80 columns (not part of this PR)
- The header line `HTTP [partial] · operator quiz read failed +1 · partial: Candle failed` and the 200-column right pane `feed closed: MCP initialize: HTTP 40…` come from the synthetic server, which serves no quiz or Candle route and refuses the MCP POST. They are not a product observation

## 적용범위 (Scope)

- 영향 받는 영역: TUI Keepers list rows, the Keeper columns help sheet, `docs/TUI-GUIDE.md`, `docs/guides/TUI-KEYS.md`
- 제약/배제: no server code, no live server, no installed TUI touched; the capture server listened on loopback ports of a scratch workspace
- 롤백 조건: this directory only documents captures; reverting PR #49624 reverts the behaviour
