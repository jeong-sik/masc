# Mixed TUI rows: source change and verification scope

## Motivation

The parent ASCII-layout branch's [focused CI run](https://github.com/jeong-sik/masc/actions/runs/36013227667)
at `be57a65e6d624043e3841ec6bc95b0f25543c8db` observed these 120-cell rows:

| Row | Width CPU microseconds/op | Allocated bytes/op |
| --- | ---: | ---: |
| Printable ASCII | 0.204 | 64 |
| 118 ASCII characters followed by 한 | 11.643 | 18,944 |

Each observation batches 2,000 operations and includes harness overhead.
These measurements identify a remaining path through Unicode segmentation;
they are neither this change's results nor input-to-frame latency.

## Change

Keep one Uuseg segmenter per valid text range. Feed the first and last ASCII
scalars normally, but emit interior printable ASCII as individual display
pieces. The first scalar retains preceding Prepend context, and the last
retains following combining, spacing, joiner and emoji selector context.
The whole-range malformed UTF-8 fallback and CSI splitting stay in place.

This follows [UAX #29 grapheme rules](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundary_Rules).
The installed Uuseg 17 implementation was also inspected: drained printable
ASCII leaves the segmenter in Fill with Other/None break properties, cleared
regional-indicator parity and emoji context, and reset Indic context.

Adversarial review identified that creating a new segmenter at every short
ASCII run would increase allocation. The revised implementation reuses the
single segmenter. Review response also replaced the width oracle with explicit
expected cluster widths and added EOF and prior emoji/RI/Indic contexts.

## Verification status

- `git diff --check`: passed.
- No local build. [Focused CI 36023767765](https://github.com/jeong-sik/masc/actions/runs/36023767765)
  passed all 103 layout cases at source commit
  `06e8ed5effeafd739b18802ed19a763d0c962ac4`.
- CI suite: `test_tui_message_layout`, including cut/wrap boundaries and
  observation cases for ASCII, CSI, late Unicode, leading box drawing, short
  mixed runs and pure Unicode. No timing threshold.
- Runtime comparison and the overall 0.1ms objective remain unproven.

Candidate width observations in that run (2,000 operations each):

| Row | CPU microseconds/op | Allocated bytes/op |
| --- | ---: | ---: |
| Printable ASCII | 0.186 | 64 |
| Late Unicode | 4.429 | 11,640 |
| Leading box drawing | 3.915 | 11,728 |
| Repeated short mixed runs | 8.610 | 16,992 |
| Pure Unicode | 8.836 | 14,768 |

The parent observations above came from a different CI run. These observations
do not establish a controlled speedup or terminal response latency.
