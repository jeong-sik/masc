# Queue layout: actual terminal comparison

These are manual observations of a real macOS arm64 TUI in a private tmux
session on 2026-10-29 KST. All conversations and queue items are fabricated.
The loopback fixture acknowledges an operator request without applying it or
executing anything. No production Keeper, model or bearer credential was used.

The [manifest](manifest.json) binds retained capture bytes to source
`38b6edd82eaac14cf7141fb83988108b7883f1dd` and executable SHA-256
`95d7e56201232bba05998c8f19a137074bd901c0a236d102637173a68e4b191a`.
The executable's `--build-commit` matched that source. Provenance:
**Minimal manual checks**, [run 40729189710](https://github.com/jeong-sik/masc/actions/runs/40729189710),
workflow ref `main` / `571f74aff49894e2a193dc7deaf1e71fb2787667`.
The overall run concluded **cancelled**; the `native-tui / macos-tui` job
concluded **success** and published this executable. Its
[receipt](native-receipt.json) records three passing detail-ownership suites,
which do not establish Queue layout or the manual observations below.

Hints were enabled throughout these comparisons. HOME, workspace and PATH were
isolated. Unimplemented fixture reads return 503; the generation-mismatch
footer is expected. The [fixture source](fixture.py) serves eight authored chat
messages, 18 pending events, one running row and a future schedule. Each
adaptive/full pair keeps the same executable, fixture, selection and receipt
state. Absolute elapsed-age strings naturally advance between captures.

## Capacity and context

Counts below are an analyst's reading of the saved terminal frames, not screen
assertions or a speed/readability measurement.

| State | Adaptive capture | Full capture | Observation |
| --- | --- | --- | --- |
| 120×36, first event selected, no receipt | [Side](candidate-selected-adaptive-120x36.txt) | [Full](candidate-selected-full-120x36.txt) | Both show 18 pending events. Side also shows eight authored chat messages; item text truncates sooner. |
| 80×24, same selection, no receipt | [Bottom](candidate-selected-adaptive-80x24.txt) | [Full](candidate-selected-full-80x24.txt) | Five versus ten pending events. Bottom's three preview rows show trailing read diagnostics rather than authored messages. |
| 80×24, selected event with receipt | [Bottom](candidate-after-immediate-80x24.txt) | — | Four pending events remain visible; do not compare this to the no-receipt count as a controlled layout pair. |
| 160×40, selected event with receipt | [Side](candidate-selected-adaptive-160x40.txt) | [Full](candidate-selected-full-160x40.txt) | Both show all 18 pending events. Side retains conversation and read diagnostics. |
| 80×16, selected event with receipt | [Full fallback](candidate-selected-short-80x16.txt) | — | Adaptive already uses Full at this short height. |
| 80×24, zero events | [Bottom](pending-0-adaptive-80x24.txt) | [Full](pending-0-full-80x24.txt) | All Queue facts fit in both. |
| 80×24, one event | [Bottom](pending-1-adaptive-80x24.txt) | [Full](pending-1-full-80x24.txt) | The one event and Queue facts fit in both. |

The zero/one-event cases use [a derivative fixture](pending-count-fixture.py)
with an explicit event-count argument and no running/scheduled rows. They
are separate fixtures, not comparisons against the 18-event data. The
[research decision](../../../research/2026-10-29-tui-queue-layout-comparison.md)
uses this evidence to reserve narrow context for spare space. That revised
placement policy and later viewport-admission/footer changes are newer than
this executable; these captures do not validate those changes.

## Keys and parent/child layers

[Help](candidate-help-80x24.txt) opened above the selected Queue;
[Esc returned](candidate-after-help-80x24.txt). Enter opened
[detail](candidate-detail-80x24.txt), exposing the complete selected item and
`fixture-event-01`, incarnation `1`; [Esc returned](candidate-after-detail-80x24.txt).
After these transitions and layout/resize changes, `n` and `l` produced the
last two entries in [operator-requests.jsonl](operator-requests.jsonl): the same
ID/incarnation with `immediate` and `low`. The first two entries belong to the
earlier `0bf908e` baseline. The file is a derivative selecting the exact
operator POST path from a raw request log; headers were never logged.
[Action notes](actions.jsonl) retain the input sequence and its limitations.
They are manual notes, not a complete input event log.

The TUI's receipt says the server confirmed an update. Here that means only
that the synthetic endpoint returned HTTP 200. Its response explicitly says
`execution: not_performed`; neither the request nor the receipt proves a real
queue reorder, schedule change or model execution.

## Copy boundaries and covered draft

Synthetic SGR mouse reports were sent while the real TUI owned the terminal.
tmux's `set-clipboard` was off. The decoded
[OSC 52 requests](candidate-pointer-copy-requests.json) contain, respectively,
only the left conversation document and only the right Queue document. The
left drag crossed the pane boundary. A third drag started on the left, held
while `f` changed placement, and released after the replacement frame produced
no copy request. The [before](candidate-before-pointer-120x36.txt) and
[after](candidate-after-transition-drag-120x36.txt) frames preserve its context.
The raw terminal-output digest is in the manifest; raw bytes remain in the
local observation directory. An OSC 52 request is not OS clipboard acceptance.

With the synthetic draft `iORIGINAL-DRAFT`, Ctrl-X opened Context and a
bracketed paste supplied `CONTEXT-PASTE-MARKER`. The
[Context capture](candidate-context-after-paste.txt) shows a paste rejection;
[returned chat](candidate-chat-after-context-paste.txt) retains only the
[original draft](candidate-chat-before-context-paste.txt). The leading `i` was
literal input, not an editor-entry key. [Help](candidate-context-help.txt)
opened above Context and [Esc returned](candidate-context-after-help.txt).
This contrasts with the earlier
[0bf908e observation](../tui-panel-input-2026-10-29/README.md), where the pasted
marker reached the covered draft. It does not establish every timing or input
destination. Physical Korean IME, physical mouse/chords, browser pixel
readability, human completion time and the final revised executable remain
unmeasured.

Follow-up bundles independently retain an
[installed Lazygit observation](lazygit/README.md) and
[revised-placement/footer-condition observation](revised-placement/README.md)
on `c2bdd3c`. Their manifests do not extend the 38b6 captures above to the
final viewport-input repair.
