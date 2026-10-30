# Browser composition, live TUI and retained observations

A natural Keeper turn read three synthetic team channels through the Browser
Lane. The operator's already-open TUI followed Alpha, Beta and Gamma without
further keyboard input. A second server run, with no connected browser, read
the same Keeper's four retained observations in the TUI and copied their exact
receipt identities.

This bundle records candidate `cc757326f8ebb1d4d3d4ac08486bb507352be35f`, built by
[Native 34708736553](https://github.com/jeong-sik/masc/actions/runs/34708736553).
Its parents are TUI `ff170b018c79385816fa47a450b2ca97c1c4f96f` and content
composition `836328586ab91d272cfd5a7c4e07735b3df9d522`. It includes the palette
reopen and deferred-read repairs, but **predates the later `B` key repair**.
The revised native PTY fixture is archived separately and identified by hash
in [candidate.json](candidate.json); the fixture note describes the production
code at capture time, not the current PR head.

## Measured result

| Measurement | Observed |
| --- | --- |
| Keeper outer tool calls | 6 successful, 0 errors |
| Content compositions | 3, each navigate then read |
| Other outer calls | 2 skill loads and 1 initial scoped BrowserRead |
| Raw outer result bytes | 36,199 UTF-8 bytes |
| Retained browser observations | 4, exact bytes matched to delivered results |
| Completed live TUI frames | 53; all three channel headings, URLs and messages seen |
| Turn duration observed by the harness | 40.35 seconds |
| Historical clipboard contexts | 4; receipt, artifact, URL, document and timestamp matched |
| Owned server, driver and TUI exits | 0 |

[answer.txt](answer.txt) reports Alpha's Tuesday decision, Beta's Monday
migration and Gamma's Wednesday QA, with visible-message links and coverage
limits. It does not attribute Alpha's unspecified owner or repeat the stale
Friday navigation snippet as the current decision. These are observations from
one synthetic run, not a general speed ranking, complete archive crawl, Slack
test or proof of the currently deployed binary.

## Inspect the evidence

- [Live Gamma TUI](tui-gamma.png) and [Firefox at the final page](firefox-final.png)
  show the same test site. Alpha and Beta TUI images are also included. TUI PNGs
  are xterm replays of actual recorded native-terminal bytes; the Firefox PNG
  is an actual browser screenshot, not an image aligned to every saved scene.
- [Historical Gamma](history/gamma-complete.png) and
  [historical overview](history/overview-complete.png) show the retained source,
  observation timestamp and content while the history server has no browser
  clients. In particular the overview has four navigation rows and no stale
  channel body.
- [report.json](report.json), [receipts.json](receipts.json),
  [raw-tool-results.json](raw-tool-results.json) and [turn.json](turn.json)
  join the actual turn's execution IDs to raw tool results and composed node
  receipts. `result_bytes` is checked against the UTF-8 result, not an envelope.
- [bundle/bundle.json](bundle/bundle.json) identifies full skill packages
  exported by the measured server binary. The successful run installed those
  exports and checked their complete file inventories; it did not substitute
  a local experimental composition for a missing packaged skill.
- [retained-observation-audit.json](retained-observation-audit.json) and
  `observations/` connect exact JSON substrings in the raw replies to durable
  blobs. The audit does not reserialize JSON to make differing bytes match.
- [history/report.json](history/report.json), [contexts.json](history/contexts.json)
  and the original PTY/OSC52 stream bind the historical reader to the same
  candidate and fresh Keeper. [tui-lifetime.json](tui-lifetime.json) records
  operator input and the live TUI's lifetime through the turn.

The original historical screenshot capture stopped after drawing the header,
in the middle of a terminal frame. The resulting `*-partial.png` files are kept
as failed captures. No product failure or successful full-body rendering is
inferred from them. For each selection, `observation-N-complete.pty` is the exact
prefix of the original `history.pty` through the next frame terminator
(`ESC[?7h`); [capture-boundaries.json](history/capture-boundaries.json) records
both offsets. The `*-complete.png` images replay those complete prefixes.
The archived capture script includes the subsequent frame-completion wait fix;
it was not rerun for these historical images. The independently checked
prefixes provide the corrected evidence from the original full recording.

## Verify from the checkout

```sh
python3 docs/evidence/browser-delivery-20260913/audit.py
```

The audit uses only Python's standard library and the committed bundle. It
checks the complete hash inventory, package and binary identity joins, exact
raw-result bytes, composition receipts, historical contexts, complete frame
boundaries, live-follow records and cleanup. It does not start MASC, access
credentials or contact a website. PNG integrity is checked by hash; a visual
review or replay is needed to judge the rendering itself.

To independently replay a historical frame, with `ttyd`, Playwright and its
Chromium browser installed:

```sh
python3 docs/evidence/browser-delivery-20260913/scripts/replay.py \
  docs/evidence/browser-delivery-20260913/history/observation-3-complete.pty \
  --columns 130 --rows 35 --output /tmp/browser-history-overview.png
```

The other `scripts/` files preserve the original collection procedure. Some
depend on temporary worktrees, installed native tools and the operator's local
runtime configuration paths, so they are not portable one-command reproduction
instructions. No credential file or credential value is included. Runtime
configuration and process lifetimes from this isolated experiment are evidence,
not deployment instructions.
