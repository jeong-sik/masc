# Board posts application query attribution

Source comparison base: `526630276d0c9b467e860d7f8c59b34fcdc0b31d` (#43750).
This source-derived Before/After is not an observed runtime log or timed result.

## Finding and behavior

Both `tui_dataset_early` and terminal `tui_surface_read_applied` identified original
request ownership and received/failed dataset outcome but omitted the query now
carried by Board receipts. A failed replacement could involve three different
queries: its frozen input, the operator's later controls and the retained successful
listing. Missing terminal posts were marked unavailable in state but omitted from
the applied sources array by `Option.iter`.

| Case | Before | After |
| --- | --- | --- |
| Board early/terminal application | Request, dataset, received/failed | Same plus shared typed query projection |
| Received/failed receipt | Query available only in local receipt | `delivery_query` retains frozen input |
| Controls changed during I/O | Application controls not distinguished | `requested_query` captures them separately |
| Failed replacement | Retained list query not joined in log | `listing_query` is the retained successful query |
| First failure | No successful list | `listing_query: null`, not current controls |
| Successfully empty list | Successful query in state | Real listing query, distinct from no observation |
| Owned terminal missing result | No applied-sources entry | `missing`, with `delivery_query: null` |
| Consumed/superseded/withdrawn slot | No admitted application | Still no invented application entry |

One immutable application value returns from the actual canonical state transition.
The existing error-notice policy remains in the caller. Early application obtains
that value only after existing workspace/refresh/opaque dataset admission. Terminal
Board application remains inside workspace admission and the remaining-datasets
check; `None` there captures a missing observation after the existing terminal
reservation has marked unavailability. Non-Board applications retain their fields
and their data transitions; they do not acquire Board metadata. Collector cleanup
without terminal application is not relabelled as a new application receipt.

The schema-1 Board object contains outcome plus delivery/requested/listing query
objects. Query objects contain the closed sort's wire label and optional hearth.
A query object's null hearth means all hearths; a null query object means no proof
for that query. Missing has no query payload in the closed delivery variant, so
controls/retained rows cannot accidentally supply it. JSON is output-only; no
label/error comparison or log parsing influences product control flow. No row,
post body, draft, failure text, credential or workspace path is copied into this
projection. It does not retain the whole receipt or add history to UI state.

## Source quantities and limits

For Board application, query-context fields change from 0 to 3. A missing result
under a still-owned workspace-admitted terminal posts slot changes its sources
entries from 0 to 1; already consumed or rejected posts remain 0. This is a source
branch/count comparison, not a sample cohort. New HTTP/health reads, clocks,
request generations, retries, limits, log streams and screen rows: all 0.
The two Board GET readers remain two. JSON projection/encoding adds unmeasured
work; no loading, input, model preparation, paint or useful-work speedup is claimed.

Four existing availability/query/ownership scenarios are extended (the suite remains
six cases, with no new independent helper tests). They inspect actual application
return values across first failure without a successful query, received rows, three distinct queries on failure, a later
empty success without rewriting earlier context, superseded/duplicate ownership,
terminal fallback, missing data with retained empty success and withdrawal. Palette
and key fixtures explicitly ignore the new diagnostic return value. Assertions
inspect typed state, observation and decisions; no wording/layout/screen-order,
snapshot-output, serialization-string or PTY expectations are introduced.

These scenarios are authored and unexecuted. Private producer/event-loop logging
paths and serializer cases are inspected in source, not executed by the scenarios.
No facade/library extraction is added. Only parsing and diff/changelog metadata
checks run here; no local Dune/typecheck/tests, CI dispatch/watch, native/model run,
install/restart, live prompt/config write, independent approval, own merge, actual
runtime log or paint proof. Full preparation/discovery reuse, cold-start input and
TUI visibility, Ask-to-original-Task/useful-work, resource-owned Composition,
held-job/shared-backend and matched Before/After scope remains active. Failed,
cancelled, interrupted and unfinished samples remain part of that goal.
