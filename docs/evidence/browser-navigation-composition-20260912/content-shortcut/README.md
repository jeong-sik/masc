# Fewer decisions, but missing intermediate TUI pages

This separate native MASC composition experiment changes the read after navigation
from regions to unscoped visible content (`experimental-skill.md`). It ran against
the same isolated fixture and same server/TUI binaries as [the region route](../composed/README.md),
using `codex_subscription.gpt-5.6-luna`. The site instruction also explicitly
distinguishes authors from assigned owners; this confounds answer-quality attribution.

| Observed run | Outer calls | Failed calls | Compositions | Observed seconds | Full outer result bytes | TUI page/message pairs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Regions then scoped article | 10 | 1 | 3 | 55.832 | 21,904 | 3/3 |
| Visible content immediately | 6 | 1 | 3 | 35.336 | 22,033 | 1/3 |

The results show fewer model invocations, not lower returned payload volume. These
are single runs with different plans/instruction text and polling latency; the
time difference is not a causal speed benchmark. Neither run should have made
the initial unsupported BrowserRead request; the failure is retained. The content
answer correctly leaves Alpha's owner unspecified and includes the current
decisions, two Mina requests, shared work and source links. Coverage remains
the fixture's visible viewport, not hidden history.

All three composition calls and their navigate/read nodes completed. The tool
receipts retain result_bytes and truncated_to: the dashboard log truncates larger
outputs at 4,000 characters, so `raw-tool-results.json` supplies complete results
from the native trace, joined by exact tool_use_id. `composition-audit.json`
checks those joins and validates observed URL/tab/content. Byte counts are actual
UTF-8 result strings, not complete provider wire input size.

The TUI was put in Page content before the Keeper started. No input followed.
Its default cadence captured Gamma's URL, heading and message, but Alpha and Beta
were absent from all 47 complete frames: the three browser visits settled in a
short consecutive sequence between refreshes. `tui-follow-audit.json` records
that failure, rather than treating final Gamma as proof of every channel.

Faster browser operation should not be delayed to make it look observed. To let
the user inspect those intermediate pages, a subsequent TUI feature needs the
already-recorded browser observations with their URL/document/scope identity,
and must distinguish retained observations from the live page before interaction.
This experiment does not implement that feature.

`firefox-final.png` is an actual isolated Firefox screenshot; `tui-gamma.png` is
xterm replay of native PTY. No live Slack session or user executable was touched.
