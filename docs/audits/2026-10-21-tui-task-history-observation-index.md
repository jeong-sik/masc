# Task history continuation membership

Follows the real-producer metadata repair #44798 and Task history #44786 on
Native Stack #44161. Work Task detail and Tools original Task detail both use
`Tui_decode_task_inspection.history_page` through the existing
`fetch_task_history_page` CPU decode path.

## As-Is / To-Be

| Boundary | Before | Source behavior after this change |
| --- | --- | --- |
| Duplicate within a page | Every decoded row scans the preceding rows. | A local immutable set records exact source/file/byte-offset membership while every original row is decoded. |
| Duplicate across pages | Every incoming row scans all events in the captured prefix. | The validated prefix carries its immutable observation set. The new page must be disjoint before the sets and event lists are combined. |
| Reading order | Original producer source order. | The same original list is returned, with the new page appended in that order. Set iteration never determines event order. |
| Ownership | Task identity, cursor echo, source coverage and requested demand are checked. | Those checks still precede continuation admission. The index is not a cursor, source authority, freshness claim or cross-workspace cache. |
| Failure | Repeated physical observations refuse the page. | The same refusal remains, including rows repeated with changed content. Different physical sources are distinct even if file day, offset or content agree. |

## Quantitative source comparison and actual Before/After

For a page with `p` rows and a retained prefix with `n` rows, the removed inner
linear scans could compare up to `p * (p - 1) / 2` prior rows within the page and
`p * n` prior rows across pages. This is a source operation bound, **not a time
measurement or speedup prediction**. The replacement performs balanced-set
membership, disjointness and union. Its allocation/comparison cost must be
included; it retains one physical-origin entry per observed event. The existing
immutable event-list append, JSON validation/decoding, cursor-list checks,
physical store scans, HTTP waits and display preparation still have costs.

No matched execution material for this indexing change is available. The earlier
operator reply reported no retained runs; the later #44798 records its author's
real-producer failure on an earlier candidate, not an indexing Before/After pair.
A future comparison must use the same Task, both original source inventories and captured
ceilings, page demand, page sequence, workspace and installed runtime identity.
Include initial/cold index creation, later pages, empty/exhausted pages,
duplicates, malformed pages and failed/cancelled/interrupted/unfinished reads in
their original denominators. Report actual client/decode waits separately from
server reads, UI admission, input responsiveness and paint. No displayed UI or
Loading improvement is established here.

## Existing real protocol scenario and evidence limits

The existing `test_task_history_current_sources` scenario already creates an
actual Task through the production hook and writes the two current source stores.
It now passes every actual older page through the captured TUI continuation,
keeps original source order, and refuses a real earlier physical observation
replayed under a later page's correct cursor. Its existing same-page duplicate
and conflicting nested Task checks remain. This authored extension is
**unexecuted**; no helper-mirror, count, wording, layout, snapshot or PTY test is
added.

Validation is OCaml parsing plus source/dependency and whitespace inspection.
No build, typecheck, test, CI dispatch/watch, native/model/PTY/controller/report
execution, installation, restart, live configuration write or merge is performed.
Independent current-head source review is requested separately.
