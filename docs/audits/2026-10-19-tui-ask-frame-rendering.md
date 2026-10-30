# Prepare only the question blocks demanded by one compact render

Source comparison base: `c669fa31bf87388b2bbbbb1a002bb3400c349124` (#43815).
This is source work-count reasoning. No renderer or timing cohort was executed.

## As-Is / To-Be

The compact Ask panel already retains a selected preview when a complete
question cannot fit. It still renders every question into a full string buffer,
renders the reason, maps every height, and then chooses a small window. The
fitter repeatedly searches a linked height list by index. Most question buffers
can be discarded after this preparation.

The caller now creates question references and private deferred cells for one
synchronous draw. The fitter requests stable heights by original question
index; each distinct demanded question is formatted once, using the same
original terminal-safe renderer. Emission reuses that exact buffer. Direct
array indexing replaces linked-list height lookup, and emission visits only
the selected window. A reason provider is not called when no reason or notice
row could fit.

| Boundary | Before | Source implementation |
| --- | --- | --- |
| Full question buffer constructions | All `N` original questions | `D` distinct indices demanded by fit or emission, `D <= N` |
| Repeated fit/emission of one question | Eager buffer reused | Same result reused within that draw |
| Height lookup by question index | Linked-list search | Original-index array access |
| Reason buffer when no content space remains | Constructed and discarded | Not constructed |
| Reason buffer when space remains | Constructed once | Same full construction once when queried |
| Question metadata/count | Full original inventory | Same full count and original objects; `O(N)` metadata still allocated |
| Draft/editor input | Shared helper reads mutable UI state | Helper receives explicit immutable editor snapshot; both callers updated |
| Cache lifetime | One eager draw | One synchronous draw; no cells escape |

`D` includes fit probes that do not end up displayed, such as the first question
that overflows a candidate window. It is not limited to visible questions.
When all questions are needed, `D = N` and the deferred cells add overhead.
The currently selected long question is still fully formatted when its height
is required. No bounded approximation or arbitrary content cap is introduced.

These are source construction counts and lookup structure, not observed call
counts, CPU savings, allocation measurements or speedup. Metadata arrays/cells
have a cost, and reason text may still be formatted for a hidden-reason notice.
End-to-end render/Loading latency remains unmeasured.

## Frame-local data and shared-helper scope

The cells capture the exact selected Ask row/question objects, immutable draft,
editor value, column count, answering flag and locally clamped question cursor.
They do not capture mutable UI state. `draw_ask_question` now takes the original
editor snapshot explicitly; its existing Ask-ID and question-ID editor guards
remain in place. Its only two callers, compact Approvals and the full reader,
are updated together, and the interface is updated with the implementation.

`Stdlib.Lazy` is private to this synchronous draw. Only the fit callback and
the subsequent emission force a cell; no callback/cell is stored in the plan,
returned, put in shared state or handed to a worker/fiber. No cross-frame,
cross-Ask, workspace, width or theme cache is added. A new draw starts with new
cells, so later input or terminal changes cannot reuse a prior draw's buffers.
This is not a concurrently shared Lazy or an Eio worker cache.

The full original inventory still determines totals and hidden counts. Unforced
question buffers are not missing source data, nor are they new successful
observations. Original question text, choices, draft/free-text values and the
complete scrolling reader remain available. No submission, read, effect, default
selection, Task/Goal completion or action authority is inferred from formatting.

For stable original heights, fitting order and row decisions follow the same
branches as the parent implementation. Context is skipped only when both its
full body and its notice cannot be drawn; this is not a claim that the reason
is absent. The compact preview and notice budgeting remain unchanged.

## Evidence and remaining goal

OCaml parsing-only covers layout, compact renderer and shared primitive `.ml`/
`.mli`. Diff/changelog checks cover metadata. No wording, layout, row-order,
snapshot, PTY or implementation-mirror invocation-count tests are added. No
build, typecheck, test execution, CI dispatch/watch, native/model run, install/
restart or real Before/After frame accompanies this layer. Syntax and source
reasoning do not prove types, behavior, input response or physical paint.

Independent current-head review remains pending. The complete objective stays
active: original Ask/Task/useful work, exact frozen preparation, ordinary/nested/
dynamic/effectful resource continuity, held/shared-backend work, TUI readability/
visibility and matched real observations retaining failed, cancelled,
interrupted and unfinished attempts require their own evidence.
