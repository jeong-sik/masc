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
