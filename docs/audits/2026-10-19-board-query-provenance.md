# Board list query provenance

Source comparison base: `b4b394ccd862afa416cdd85fd1bcc3e6e559dc74` (#43746).
This is a source-derived Before/After, not a timed comparison or runtime verdict.

## Finding and resulting behavior

The full and navigation dispatchers already captured sort/hearth before I/O.
However, early `Dataset_board_posts`, terminal `http_board` and the stored Fetched
value contained only rows/results. Rendering read the mutable controls. Changing
from recent/alpha to updated/beta could therefore leave alpha rows beside beta's
heading, a changed-time age column and beta's census total. Ready-but-different
rows could also lack a retained label after the original read settled.

| Boundary | Before | After |
| --- | --- | --- |
| Dispatch | Two immutable local filter values | One typed immutable query |
| Early and terminal posts delivery | Bare Result | Same query-bound receipt shape |
| Successful list value | Rows | Query and rows, including empty |
| Controls change or replacement fails | Rows keep no source query | Previous query survives with previous rows |
| Heading/time column | Current controls | Observed query, with requested query separately qualified |
| Header/sidebar holding | Current hearth | Observed hearth in received independent census |
| Palette | Retained only by availability/pending | Also retained when query differs |
| Detail enrichment | Matching row, no rerank | Same behavior; query/failure/pending preserved |
| Workspace withdrawal | Remove listing | Remove rows and origin together |

The request's query does not certify server completeness, a backend transaction,
a newest observation or authorization. Existing workspace preconditions/server
receipts and refresh/dataset admission are unchanged. Superseded/duplicate results
cannot apply merely because their query matches controls. Collector completion
without a result records failure, not a fabricated query. Failure diagnostics keep
the existing last-error policy; this layer records successful-list provenance,
not a history of failed queries.

No new HTTP/health reads, independent request generations, clocks, retries, caps,
configuration knobs or screen rows. The two existing Board GET readers remain two.
The independent posts/hearth delivery and census availability rules remain intact.
Query fields are immutable metadata; no list re-sort or re-filter runs in the UI.
The palette's origin suffix is formatted once per candidate-list construction.

## Authored scenarios and evidence limits

Three existing list availability/selection scenarios are adapted to canonical
query-bound snapshots. Three additional compound state/ownership scenarios cover:

1. Controls change before an owned response; original query, time semantics and
   matching census total survive, followed by failed replacement, detail enrichment,
   preserved compose input and an actual empty replacement query.
2. Full/navigation overlap, rejected superseded/duplicate delivery and a terminal
   fallback using its captured query after controls move again.
3. A successful empty query survives a missing replacement result; workspace
   withdrawal removes its origin and rejects a retired response.

Existing palette/key fixtures use canonical receipt application. Census scenarios
pass their intended hearth explicitly. Assertions inspect typed data, ownership,
selection and decisions; they do not test UI wording, layout, screen row order,
snapshots or PTY output. The async protocol is an executable-private module;
state scenarios do not import it or claim to execute the private producer/loop.
Both producer/application paths and the matching `.ml`/`.mli` contract are traced
in source. No test-only facade or library extraction is introduced.

Only parsing and diff/changelog metadata checks are allowed in this implementation
unit. No local Dune, typing, scenario execution, CI dispatch/watch, native/model run,
installation/restart, live prompt/config write, screen paint or measured speedup.
Independent current-head review/approval remains pending; author inspection is not
independent review. The full preparation/discovery reuse, cold-start input and TUI
visibility, Ask-to-original-Task/useful-work, resource-owned Composition,
held-job/shared-backend and matched Before/After goal remains active. Failed,
cancelled, interrupted and unfinished samples are not dropped from that goal.
