# Actual navigation composition and shared page content

An isolated Firefox session and Keeper completed the three-channel fixture through
Browser Lane on 2026-09-12. The candidate server was the CI-built `cd7f637eca`
binary (SHA-256 `08f3ce42a9ebbf2c5dc2f14e50dd390e45c8c0cdf0c59f4218168ef591525e7d`).
The persistent TUI was the separately verified `c2304e75b9` binary (SHA-256
`821a88fe8299a0e367496adff2e65ddaafd3af6f6de9be4c0c5712e9a5a6d781`).
No user executable or live Slack session was changed.

The Keeper used `codex_subscription.gpt-5.6-luna`. Typed TurnRecord execution IDs
join to **10 outer calls**, with **one failed call** and **three successful
`keeper_compose_browser-navigate-regions` calls**. Each composition executed
BrowserGoto followed by BrowserRead regions on the pinned tab; each returned
document/region identity was used for the corresponding article read. The six
inner browser calls and three composition summary records are not extra model
invocations. `execution-receipts.json` and `turn-execution-ids.json` retain that
join; `composition-audit.json` includes the answer and checked navigation routes.

The original harness's `report.json` has empty `model_tool_calls` and zero
`composition_invocations`: it looked only at standard chat message envelopes,
which omit native app-server tool invocations. Those fields are not authoritative
for this run. The durable execution-ID join supplies the actual counts. The
21,904 outer result bytes are durable logged payload bytes, not a provider wire
input measurement. The observed 55.832 seconds includes status polling/query
latency and uses a different provider from earlier runs; it proves no speedup.

The TUI displayed **all three current URLs, channel headings and message text**
in 79 complete captured frames. After copying the initial region context, the
operator selected Page content before starting the Keeper. The six initial input
events are recorded; no input occurred after Keeper start. The TUI showed the
whole visible page while the Keeper read an article scope; their scopes were not
identical. Captured PTY was replayed in xterm for `tui-*.png`; these are not
physical-terminal screenshots. `firefox-final.png` is the actual browser capture.

## Remaining shortcomings

- The Keeper loaded the site instruction but skipped the base browser instruction,
  then attempted elements with expectedUrl, which is unsupported. It recovered
  through regions/scene reads; this extra failed call remains in the evidence.
- The answer calls Alpha speaker Hana the owner, although the fixture does not
  explicitly assign that responsibility. Decisions, mentions and links were
  collected, but full answer accuracy is not established.
- This is one synthetic site. The unscoped-content shortcut and comparable
  provider/model runs still need measurement.

The copied audit scripts document the checks performed against the complete raw
experiment directory. This publishable subset omits full runtime prompts and
private service state, so those scripts require the original API envelope files
when rerun. The retained execution receipts, IDs and scene/PTY data make the
reported route and display claims independently inspectable.
