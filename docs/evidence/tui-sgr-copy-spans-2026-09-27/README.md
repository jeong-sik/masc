# TUI style removal with whole-span copies

The existing five-second native sample of verified artifact source
`f69b7b40a379f3b3ff7fd8060b041d0315b15851` contains 47 self samples in
`Masc_tui_theme.strip_sgr`'s byte-copy loop. Its theme source is byte-identical
to this PR's base. `observation.json` records the source/profile hashes, every
matching profile coordinate and the retained original profile link in #39313.

This is a source investigation clue, not a dominant-bottleneck estimate or a
before/after speedup. That older profile sustained a modified synthetic Info
scrolling workload and perturbed execution; its child resource totals included
the profiler and are not TUI CPU measurements. The current change has no
candidate performance result yet.

Previously, every ordinary byte passed through Buffer.add_char and even plain
text allocated a buffer and result. The new scanner locates SGR openers and
copies intervening byte spans with Buffer.add_substring. A string with no SGR
opener is returned unchanged. The first following m ends an opener, an
unterminated opener drops its suffix, and isolated ESC bytes remain intact.
No Unicode decoding, width policy or style syntax is changed.

Existing selected-row/theme tests remain. Literal edge cases cover adjacent
styles, a trailing opener, isolated escape bytes, multiline arbitrary bytes,
unterminated suffixes and nested openers; plain-text physical reuse is checked.
Source/interface/test syntax and diff checks passed. Independent review and
compiled CI are recorded in the PR. No local OCaml build, allocation-volume
measurement, latency speedup, production change or 0.1ms achievement is claimed.
