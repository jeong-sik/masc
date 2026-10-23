# Original MIDI note-edit latency

Local macOS / Node v26.3.0 observation, 2026-10-23. Baseline source modules match main `2aab885ae5c456dc015a03f206894f688b803fb6`; measured candidate is `4af29747935ce74c3e0dc03204a30b47eef1364a`. Later documentation/fragments do not alter measured product source.

The manual runner is `node tools/alphatex/bench/source-note-edit.mjs [ALTERNATE_ALPHATEX_DIRECTORY]`. It imports the actual editor and source modules from the selected directory. The fixture is same-key MIDI1 PPQ960 notes, separated by one beat with an initial quarter-beat duration. Fixture construction and selection are outside timing. Each measured edit is `duration-add-notes 1/4`, and every output note is verified as 480 ticks. The separate guard measurements rerun the actual guard three times on the edited performance.

| Notes | Editor before (ms) | Editor after (ms) | Guard before, three runs (ms) | Guard after, three runs (ms) |
| ---: | ---: | ---: | --- | --- |
| 1000 | 108.581 | 30.404 | 21.948, 15.659, 16.334 | 1.552, 1.226, 0.885 |
| 3000 | 794.845 | 80.628 | 171.622, 173.694, 171.083 | 2.705, 2.517, 2.679 |
| 6000 | 3063.581 | 130.376 | 701.731, 697.075, 697.392 | 5.102, 4.930, 13.427 |

The range index preserves the exact original on/attack/off predicate: among attacks inside a new interval, original-rank minimum/maximum must also lie strictly inside its original interval. Index construction is linear in events and queries are logarithmic per paired note. Batch-local Maps replace repeated source patch-array filtering and are serialized once before the unchanged source validation; last-touch patch order and insertion order remain intact.

Focused validation: 77/77 Node cases (see the PR for the exact suite list), including original source note/expression/tempo/meter edits, same-tick order, raw and paired endpoint overlaps, exact clocks, copied runtime imports, and harmony/arrangement save/export. The performance experiment is informational and has no timing assertion. One editor sample at each size and three guard samples are not a general workload, statistical benchmark or installed TUI latency result. Dense explicit expression-order groups, source parsing, serialization, allocation and worker scheduling remain outside any broad speedup claim. No installed binary, live server, actual device playback or audibility was checked.
