# Chat scroll prefix-index component measurements

The full 0.1 ms/30-to-300-agent goal, native TUI scroll/Page Down/navigation,
DAW and visible flicker requirements remain unproved. This bundle supports one
source change to the existing chat row-count cache, not installation, full UI
frame performance, or a whole-product verdict.

## Source change

The old cache saves each entry's height but still re-adds the known newest
suffix and walks it again when selecting a deep viewport. The candidate stores
cumulative endings in that same array, uses lower-bound searches, and extends
only previously unmeasured entries. Original body-anchor lookup shares the
same cumulative values. No additional mutable field, global cache, option or
lifetime is introduced; entry identity, width and origin continue to select the
existing cache. Zero-row entries retain the first equal ending rule.

`source-bindings.json` records the actual current file hashes. The historical
whole candidate hash differs because the applied source corrects an explanatory
comment. Both executed algorithm fragments occur byte-for-byte in the current
product source; historical manifests are not overwritten to claim full-file
identity. An earlier unretained tool self-report was `8c08d4c…`. The fresh retained
`installed-baseline-observation.json` self-reports `f06ab8f…` with a different
binary digest, showing that the shared installed baseline moved between reads.
Neither observation is a timed comparison against an installed candidate.

## Observations and verification scope

`count-v1` extracts the actual count/index fragment with an explicit integer
row-count adapter: 72,240 decision checks. `window-v2` extracts the actual
viewport and body-anchor functions too, using synthetic Body/Metadata/Spacing
records: 113,100 scroll/input-anchor decisions agree with independent flattened
oracles. This tests stored scroll values and original body identities, not
screen text, appearance or expected row layouts. It does not model real
Markdown, Unicode, entry generation, asynchronous UI ownership or painting.

Every size has eight AB/BA batches for before/after and hot/cold state. Hot
counts are prefilled; cold includes new arrays and simulated row generation.
The tables are medians of batch means, not per-call percentiles. The shared host
was not quiesced. Compiler: OCaml 5.5.1, standalone native programs using the
default runtime. The product TUI's own heap/pool setup is not reproduced.
Extra final empty lines in six retained carrier modules were removed for Git
whitespace validation. `provenance.json` preserves distinct original/retained
digests; these EOF-only derivatives are reproduction source, not the original
compiled byte stream. Original programs remain under ignored artifacts.
Native executable hashes before and after each complete program match its
recorded compiled binary; successful program exit and original output remain
retained. No local product/Dune build was run.

The decisive full-window component results follow. Warm 30,000-entry wall time
falls 112.965 to 0.566 us, CPU 98.204 to 0.567 us, and allocation 657,408 to
9,440 B/call. A cold 30-entry case reports wall +0.94% and CPU +2.22%; the
count-only study also retains cold-path allocation/CPU increases. These remain
part of the evidence. The sizes are controlled input scales, not claims about
actual per-Keeper history length or 300-owner end-to-end load.

| Entries | Cache | Before wall us | After wall us | CPU ratio | Before bytes | After bytes |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 30 | hot | 0.600 | 0.505 | 0.892 | 9752.0 | 9488.0 |
| 30 | cold | 1.108 | 1.119 | 1.022 | 14916.8 | 14652.8 |
| 300 | hot | 1.738 | 0.539 | 0.353 | 15888.0 | 9440.0 |
| 300 | cold | 10.053 | 7.471 | 0.911 | 63668.8 | 57284.8 |
| 3000 | hot | 11.708 | 0.521 | 0.051 | 74128.0 | 9360.0 |
| 3000 | cold | 72.289 | 61.968 | 0.895 | 533908.8 | 469204.8 |
| 30000 | hot | 112.965 | 0.566 | 0.006 | 657408.1 | 9440.1 |
| 30000 | cold | 1052.102 | 921.847 | 0.883 | 5236868.8 | 4588964.8 |

## Unresolved single-large-entry cost

`large-entry-v3` uses the same v2 fragments and adapter. A single entry with
30,000 synthetic body/metadata/spacing rows still materializes and folds the
whole entry for a small visible window. Its component cost remains roughly
0.9–2.1 ms, with both favorable and slower observations. The empty-neighbor hot
case reports roughly +15.9% wall and +7.3% CPU; causes/repeatability are not
resolved. Allocation changes are retained in the raw records. This change does
not fix that structure or demonstrate uniform performance gains. These numbers
are not actual Markdown, physical UI or screen-flicker measurements.

| Shape | Cache | Before wall us | After wall us | Before CPU us | After CPU us |
| --- | --- | ---: | ---: | ---: | ---: |
| one-large-body | hot | 952.580 | 908.420 | 892.200 | 882.375 |
| one-large-body | cold | 1915.534 | 2066.264 | 1725.875 | 1759.950 |
| large-body-with-empty-neighbors | hot | 936.997 | 1086.339 | 860.250 | 923.125 |
| large-body-with-empty-neighbors | cold | 1979.767 | 1803.495 | 1738.775 | 1625.225 |

## Product validation and reproduction

The new actual-entry behavior test round-trips viewport body anchors to scroll
values after deep/shallow revisits, independently changed width/origin, and a
new immutable original body. It asserts decisions, not rendered text. Source
parsing passed; that product test and full integration type checking have not
yet run in this capture. Independent source/evidence reviewers found no new
P0–P2 in their recorded scope; their review is not formal GitHub approval.

To reproduce a standalone study, copy one retained version into a **new ignored
working directory**, compile with its `identity.json` argv and run `bench.exe`,
retaining stdout/stderr and actual executable/compiler/source hashes. Do not
write new output into this bundle or reuse historical identities as a new build
receipt. The adapter is visible at the start of before/after modules; raw
JSON records contain all batches. Existing real-entry tests belong to the
selected remote `test_tui_message_layout` suite. Candidate native TUI/server
artifacts and actual keyboard-to-state/Build/Present observations remain separate
required work.
