# Where the UI domain allocates on Keepers

2026-11-04. `MASC_TUI_ALLOC_PROFILE=<file>` samples the UI domain's
allocations with `Gc.Memprof` (one sample per 10,000 words) and writes the
allocation sites ranked by estimated words, as the innermost frame under
`bin/` or `lib/` and as the first eight frames of each stack.

`profile-before.txt`: the branch's TUI after the roster join fix, Keepers, 60
Down then 60 Up at 30 ms, 55 x 200, live workspace. About 71 million words
(570 MB) estimated over the run. The largest site is
`lib/time_codec/time_codec.ml:37` at 15.9% (plus 0.7% at line 53): parsing
each Keeper's last-turn time from an RFC 3339 string on every roster build.
The decoder had turned the runtime's number into that string a moment
before. The next sites are character width (`masc_tui_grapheme_segmentation`),
the roster ranking, and the agenda strip.

`profile-after-parse.txt`: the same run after the last-turn time is kept as a
number. The parser no longer appears. The largest sites are now the agenda
strip's projection (`masc_tui_agenda.ml:93`, 6.8%), character width, and the
roster ranking; the roster and the agenda strip are each rebuilt several
times a frame.

`ab-layer1-vs-layer5.txt`: the layer-1 binary (roster join fix only) against
this stack's top (last-turn number, roster and agenda reused while their
inputs are the same values), alternated three times each, with runtime
events on. Host load average 29 to 32.

| | Build p50 | Build max | UI allocated words | UI minor GCs |
|---|---|---|---|---|
| layer 1 | 1.24 to 1.56 ms | 3.2 to 14.4 ms | 76.6 to 83.6 M | 73 to 74 |
| layer 5 | 1.02 to 1.30 ms | 7.6 to 9.8 ms | 51.9 to 57.3 M | 67 to 69 |

UI allocation fell about a third in every pair. The minor collection count
over the whole run fell less than a tenth because most of those collections
happen before the TUI sizes its minor heap: in a timestamped trace of this
stack's top, about 70 of the UI domain's collections ran in the first 104 ms
at the runtime's default 256 K words, before `Minor_heap.tune`. After it, the
UI domain collected only when its 4 M-word heap was full, every 0.4 to 0.7 s
while keys were held, so a third less allocation means about a third fewer of
those. At load 30 no Build in either arm reached 15 ms; the 30 to 180 ms
stalls of the earlier runs came with load 170 to 340.

## Keeper row text (layer 6)

`profile-after-row-text.txt`: after two changes to how a Keeper row's text is
made.

- Every row built its detailed-layout second line and threw it away unless
  the layout was Detailed; on the operator's Grouped list that was a second
  detail sentence per row per frame, each one sanitized again. The second
  line is now built only when drawn.
- `truncate_middle` (the Keeper name column) built a display piece per byte
  before deciding whether to cut. It now measures first, returns a label
  that fits as it is, and cuts plain ASCII by substring.

The sanitizer left the top of the ranking and the run's estimated UI
allocation went from 51.1 M to 35.5 M words (`profile-after-row-text.txt`
against the layer-5 profile of the same scenario; those runs drew different
frame counts, so the alternated timings below are the comparison).

`ab-layer5-vs-layer6.txt`, alternated three times each, load 27 to 38:

| | keeper-list Build p50 | p95 |
|---|---|---|
| layer 5 | 1.20 / 1.24 / 1.39 ms | 2.68 / 3.18 / 3.79 ms |
| layer 6 | 1.04 / 0.89 / 1.04 ms | 1.97 / 1.65 / 2.30 ms |
