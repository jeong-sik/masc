# Final-source pixel observation, 2026-10-30

The resumed observation uses the same compiled source as the
[final terminal study](../final-23c/README.md):
`23c5ea834f89a0988c02ffe3e492980152869179`, executable SHA-256
`38e081df1926332e59e5f8edcfed8cad76c40e21afda8cde4b4fc428f9c48bab`.
No product source changed during this observation phase. [Manifest](manifest.json) binds 38 retained files,
including 11 original PNGs, browser geometry, separate terminal-row captures,
fixture request/event records and cleanup. Native build provenance remains
[run 40739146379](https://github.com/jeong-sik/masc/actions/runs/40739146379)
and its [receipt](../final-23c/native-receipt.json); no new build or CI run was
needed for this documentation/evidence phase.

The original [PR #46699](https://github.com/jeong-sik/masc/pull/46699) was
subsequently confirmed merged at head
`9808d2cc2d78ed82d77012cb5f48a5c0df89fb1a`, merge commit
`f4dd15888670e49c947e1628960d202861159e94`. These images execute the older
`23c5ea8` candidate, not that later head, current main or the installed app.
They support the scoped research decision, not a current-runtime acceptance.

## What was displayed

These are manual readings of actual images and terminal rows, not UI assertion
tests or measured human readability. Each layout pair uses the same executable,
fixture data, selected event and no-receipt condition.

| State | Images | Observation |
| --- | --- | --- |
| 120×36, 18 pending events | [Side](side-final-120x36.png), [Full](full-final-120x36.png) | Both show all 18 events; Side also shows eight authored conversation messages. Full exposes more item text. Selected event 01 is cyan with a separate selection marker. |
| 80×24, one pending event plus running/schedule | [Bottom](bottom-final-80x24.png), [Full](full-small-final-80x24.png) | Both retain every Queue item. Bottom's small preview contains read diagnostics rather than authored conversation; its partial caption and Esc path disclose that limitation. |
| 80×24, 18 pending events | [Automatic Full](overflow-final-80x24.png) | Ten pending events are visible. Selected n/l and Enter/Esc hints remain; generic navigation needs Help at this width. |
| Explicit Queue children | [Help](help-final-120x36.png), [detail](detail-final-120x36.png) | Help shows Queue's binding table; detail exposes event-01/incarnation 1 and its full fixture text. Help and detail cover the parent until Esc. |
| Returning from children | [Acknowledgement](receipt-final-120x36.png) | After Help/Esc and detail/Esc, n targets the same event and its receipt appears above the list. l subsequently targets the same ID/incarnation. |
| Context, Help and draft | [Context](context-final-120x36.png), [Help after paste](help-context-paste-final-120x36.png), [returned chat](draft-return-final-120x36.png) | Help is the displayed Context child, shows a paste-loss notice, and does not append the delivered paste marker to the covered ORIGINAL-DRAFT. Esc returns to Context ([rows](context-return-final-120x36.txt)), then chat. |

The two event-operator records in [requests.jsonl](requests.jsonl) send
`reprioritize`, first `immediate` and then `low`, for `fixture-event-01`,
incarnation `1`. These follow layout/size changes and the Help/detail round
trips. The synthetic endpoint returns HTTP acknowledgement without applying
urgency or executing anything. The receipt is evidence of that response only.
Routine MCP initialization records are separate from operator requests.

The observations support the existing conditional choice: Side when both
documents retain reading width, Bottom when every Queue item still fits, and
Full for overflow/detail. They also show its limits: Side shortens item text,
a tiny preview can retain only diagnostics, and narrow footers defer generic
keys to Help. The images do not establish a universally best layout, measured
contrast compliance, human task speed, comprehension or preference.

## Capture conditions and boundaries

Ego TaskSpace 124 / p1 displayed a read-only ttyd 1.7.7 connection to an isolated
tmux 3.6a session running the native executable. The browser did not operate a
mock DOM. The PNGs are original, unedited exports requested with `raw: true`.
The browser reports device pixel ratio 2, while the retained PNG rasters are
1165×694 and 785×466, equal to their CSS viewports. The exporter's scaling is
not established; DPR does not certify doubled raster resolution. Individual
JSON records retain viewport, measured terminal columns/rows, font settings
and capture time. The 120×36 viewport is 1165×694 CSS pixels and 80×24 is 785×466,
using font size 16 and `Menlo,Monaco,monospace`. These are browser-terminal
conditions, not a reproduction of the user's Ghostty font or physical display.

Early setup images clipped columns or included ttyd's transient resize badge.
They remain local under `artifacts/queue-layout-pixels-20261030/`; the comparison
retains later captures. The documented
[ttyd client option](https://github.com/tsl0922/ttyd/wiki/Client-Options)
`disableResizeOverlay=true` removes that transport badge. It does not change
the native TUI, hide its errors or alter its pixels. No native restart, image
editing, CSS/DOM replacement or compositing was used to produce these results.

The fixture source is byte-identical to
[the earlier controlled fixture](../final-23c/fixture.py). Its health commit is
a synthetic claim matching the executable for the ordinary-footer condition,
not a matching real server build. Unimplemented reads return 503 and remain
visible. Its fixed timestamps are unchanged: the schedule is **due** during
this phase, whereas the earlier phase observed it before that time. Age
strings advance. The current layout pairs are controlled comparisons; the two
dates are not a human before/after experiment.

No production Keeper, model, credential, real-server reorder/execution or
deployment was involved. Browser controls remained read only; native keys and
the bracketed paste were delivered through tmux. Physical keyboard/chords/IME,
physical mouse, OS clipboard acceptance and every async interleaving remain
unmeasured. The TaskSpace was finished once with no retained Pages, and the
verified owned fixture, ttyd and tmux processes were closed
([cleanup](cleanup.json)).
