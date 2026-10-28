# Final source: actual Queue and input observation

These are manual observations of the compiled macOS TUI, with fabricated
conversation and queue data. The [manifest](manifest.json) binds the retained
bytes, source, executable, fixture and workflow. Plain terminal rows establish
cell content; they do not establish pixel contrast or physical input delivery.

Source: `23c5ea834f89a0988c02ffe3e492980152869179`. Executable SHA-256:
`38e081df1926332e59e5f8edcfed8cad76c40e21afda8cde4b4fc428f9c48bab`.
`--build-commit` matched. **Minimal manual checks**,
[40739146379](https://github.com/jeong-sik/masc/actions/runs/40739146379), workflow
ref `main` / `00559066e16f85e397786d64312b0a4b8f874dc2`, concluded **success**;
the native-tui / macos-tui job also concluded **success**. The
[native receipt](native-receipt.json) records three passing detail-ownership
suites, not full regression or these manual Queue scenarios. Later branch
commits at retention change documentation/evidence/changelog only.

The [fixture](fixture.py) has eight authored conversation messages, up to 18
pending events, a running item and a future schedule. Hints are enabled;
HOME, workspace and PATH are isolated. Its health commit is a **synthetic
claim** matching the executable so the ordinary footer can be observed. This
is not a matching real server build. Unimplemented reads return 503. The
[empty comparison](empty-manifest.json) instead uses the earlier zero-item
fixture; both compared executables see its generation-mismatch warning.
No model, production Keeper or bearer credential was used.

## Capacity and selected actions

Counts are an analyst's reading of saved frames, not UI assertions or a human
speed/readability score. Each layout pair retains the same executable, data,
selection and receipt condition.

| State | Automatic | Prefer full | Observed tradeoff |
| --- | --- | --- | --- |
| 80×24, one pending event plus running/scheduled items, no receipt | [Bottom](count1-selected-adaptive-80x24.txt) | [Full](count1-selected-full-80x24.txt) | Both retain every item; the small preview shows trailing diagnostics. |
| 80×24, 18 events, first event selected, no receipt | [Full](count18-selected-adaptive-80x24.txt) | [Full](count18-selected-full-80x24.txt) | Both show ten pending events; the title discloses preference even when geometry is unchanged. |
| 120×36, same selection and no receipt | [Side](count18-selected-adaptive-120x36.txt) | [Full](count18-selected-full-120x36.txt) | Both show all 18 events; Side retains eight authored messages and truncates item text sooner. |
| 160×40, same selection and no receipt | [Side](count18-selected-adaptive-160x40.txt) | [Full](count18-selected-full-160x40.txt) | Both show all 18 events; Side retains conversation and partial-read diagnostics. |
| 80×16, first event selected | [Full fallback](short-selected-80x16.txt) | — | Selected target, n/l, Enter and Esc remain visible. |
| 80×24, no inventory items | [Bottom](empty-adaptive-80x24.txt) | [Full](empty-full-80x24.txt) | Both retain the empty-queue facts. |

The [held refresh](held-refresh-80x24.txt) still displays the last one-event
observation with a reading indicator; releasing the fixture's inventory read
produced the 18-event Full frame. The [event log](events.jsonl) records fixture
release-time values before HTTP writes, not client delivery/application.
This sequence did not inject navigation during the frame transition and does
not establish every viewport-admission race.

## Layers, repetition and wire targets

[Help](help-160x40.txt) and [detail](detail-160x40.txt) cover the Queue;
Esc returns to the [same selected event](return-from-detail-160x40.txt).
At 80×24, [PageDown](after-pagedown-80x24.txt) exposes the tail of the list;
Home and explicit selection return to the first event. The first two operator
POSTs in [requests.jsonl](requests.jsonl) send `immediate`, then `low`, to
`fixture-event-01`, incarnation `1`, through
`/api/v1/keepers/fixture/events/operator`. With no selected item,
[n gives selection guidance](empty-after-n-80x24.txt); the retained
[empty-fixture request snapshot](empty-fixture-requests.jsonl) has no operator
POST. Its routine MCP initialization traffic is not an operator action.

The fixture acknowledges without changing urgency or executing anything.
The [receipt while the follow-up read is held](receipt-while-read-held-80x24.txt)
and [after intentionally stopping the owned fixture](receipt-after-server-loss-80x24.txt)
keep that acknowledgement separate from unavailable inventory/queue reads.
The [termination record](fixture-termination.json) identifies this deliberate
failure observation. HTTP acknowledgement here is not a real-server effect.

The [action notes](actions.jsonl) record the manual sequence and timestamps;
they are not a complete input event log. Two delivered single jamo `ㅓ` keys
select the [running item](after-first-jamo-120x36.txt), then the
[first event](after-second-jamo-120x36.txt). One composed syllable `서`
[leaves that selection](after-composed-syllable-120x36.txt). Subsequent n/l
send the same ID/incarnation, forming POSTs three and four. The fifth POST
belongs to the later deliberate server-loss observation. This is a Unicode
protocol observation, not a physical Korean IME study.

## Covered drafts and discarded pointer tails

The draft begins as literal [ORIGINAL-DRAFT](draft-before-panels-120x36.txt).
Queue, Context and Help above Context each receive a distinct bracketed paste.
Returning from [Queue](draft-after-queue-120x36.txt),
[Context/Help](draft-after-context-help-120x36.txt) and
[the Unicode sequence](draft-after-unicode-120x36.txt) retains that draft without
the paste markers. This observes those destinations and sequences only.

For a paired empty-Queue probe at 80×24 in Full, the earlier `38b6edd` executable
and final executable receive the same rejected paste followed by SGR drag and
release without an accepted press. Both show a paste-loss notice
([baseline](baseline-paste-before-orphan.txt), [final](final-paste-before-orphan.txt));
after release the [baseline notice is gone](baseline-paste-after-orphan-release.txt)
while the [final notice remains](final-paste-after-orphan-release.txt).
The full source and binary identity for the baseline are in the manifest.

On final source, SGR drags in Side produce exactly two decoded
[OSC 52 requests](pointer-copy-requests.json): a conversation drag across the
pane boundary contains only the left document; a Queue drag only the right.
A third drag is held while f changes placement, retiring the gesture. A new
rejected paste is followed by its late drag/release;
[the notice remains](paste-after-late-release-120x36.txt), and there is no third
copy request. Raw output remains local; its digest is in the manifest. tmux
clipboard integration was off. These are protocol reports, not physical mouse
observations or proof of OS clipboard acceptance.

## Limits

The results support the conditional layout decision and these ownership,
targeting and recovery sequences. They do not measure human completion time,
preference, comprehension, physical chords/IME/mouse, every async interleaving,
real queue execution or production deployment. Browser pixel comparison was
not performed: the existing observation TaskSpace 112 was unavailable, and no
replacement was created. No local Dune build, screen-text/row-layout assertion
or automated PTY scenario was added for these observations.
