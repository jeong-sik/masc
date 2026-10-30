# Three-channel instruction composition experiment

A fresh Keeper received the exact 526-byte JSON copied by the native TUI from
the Channels navigation region. Its natural request asked for current decisions,
owners, Mina's mentions, shared work and message links across Alpha, Beta and
Gamma. No browser call sequence was supplied in the request.

The Keeper loaded `browser-lanes` and the small
[site instruction](site-skill.md), read the selected navigation, and reused its
observed links. Each channel was read through its regions and then its visible
message article. Both instruction deliveries join to the first scoped action
in the activation ledger. This is **instruction composition**; no
`keeper_compose_*` workflow tool was invoked.

| Measurement | Observed |
|---|---:|
| Instruction loads | 2 |
| Navigation calls | 3 |
| BrowserRead calls | 7 (3 regions, 4 scoped scenes) |
| Total Keeper tool calls | 12 |
| Tool errors / retries | 0 / 0 |
| Browser tool response bytes | 15,155 |
| Time until completion was observed | 125.647 seconds |

Elapsed time includes model work, status-request latency and polling
observation delay (a five-second interval). It is not browser execution time. There is no matched baseline, so
this result does not establish that the path is fastest. The repeated
regions → scene pair for each channel remains a concrete source of extra
model/tool round trips.

## Evidence and answer quality

- [run.json](run.json) contains the request, tool I/O, source/binary identities,
  activation ledger, final answer, measurements and cleanup receipts.
- [clipboard-context.json](clipboard-context.json) and
  [clipboard-osc52.bin](clipboard-osc52.bin) preserve the actual TUI payload and
  original sequence. The decoded payload exactly matches the model's user input
  after the natural request prefix.
- [tui-index.png](tui-index.png) is a **130 × 35 replay of recorded PTY output**,
  not a physical terminal screenshot. [tui-index.pty](tui-index.pty) holds those
  bytes. This TUI is the ba6b3a73e9 artifact; it predates the source-hint row fix.
- [firefox-index.png](firefox-index.png) and
  [firefox-gamma.png](firefox-gamma.png) are actual screenshots of the owned
  Firefox session before and after collection. All pages are in [fixture](fixture/).

The three message bodies were read without the sidebar's stale snippet. The
answer reported the Tuesday/Monday/Wednesday decisions, the two message mentions,
the shared Cedar/schema v4 work and observed permalinks. It excluded Alpha's
superseded Friday plan from current decisions and left Alpha's owner unspecified.

There are two precision limits in the recorded answer: it labels Hana the
decision-maker although the page only establishes authorship, and it promotes
the shared schema dependency into a migration prerequisite across all channels.
Those interpretations should be distinguished from explicit message facts.
Tool success and complete collection of the fixture's four visible messages do
not make every sentence of the answer proven.

The server was the installed d5fd7f3453 binary, started against the experiment's
own workspace. The instruction file is unchanged from fa93323a14; the additional
site instruction existed only in that workspace. The Keeper shutdown finalized,
and the owned TUI, server and driver exited successfully.

The TUI was closed after copying, before the Keeper navigated. This experiment
does **not** prove that an open TUI follows those subsequent navigations. It also
does not read real target channels, exercise Slack, or establish a general
performance advantage. Persistent TUI following and fewer discovery round trips
remain separate measurements.
