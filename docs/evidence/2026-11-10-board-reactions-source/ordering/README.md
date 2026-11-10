# Reaction batch ordering

A feed batch that read before a local toggle could arrive after the toggle and
its follow-up GET, replacing selected/count 1 with unselected/count 0. The new
BoardSurface regression failed at its final preservation assertion against
production head `42daf4d3`, then passed with the repair. The new test was added
locally for that baseline run; it is not present in the old commit.

The feed assigns a local revision when each batch starts. A bar records that
start order at individual GET start and GET/POST settlement, including a batch
whose loading render was coalesced. Earlier loading/ready results cannot replace
that local observation or cancel its pending GET. An unavailable result still
revokes authority and retains the previous count as historical display.

The capture used lower `68d96c32a0fb3182f7436afb181a62c7257c947d` and upper
`269438e6e3158087a8ded0587bec03466d0f6190`, after native restacking. The
[manifest](manifest.json) retains those identities and the source/capture hashes.
Later evidence-only commits must be compared to these inputs.

The actual [fixture](../../../../dashboard/fixtures/board-reactions-source/README.md)
ran in Chromium through ego-browser, space 65/page p1. It intercepted every
application fetch locally; no live Board write was sent.

1. [Initial](initial.json): two feed rows, known count 0/unselected.
2. A real click started one held POST. The visible body filter changed the drawn
   rows and started a batch that captured count 0 before the POST completed.
3. [Confirmed](confirmed.json): the released POST and actual individual GET
   supplied selected/count 1 while the older batch was still pending.
4. [Late result](late.json): that batch delivered count 0 afterward. The bar kept
   selected/count 1 and one POST total. Unknown vote controls stayed disabled.

The root opened and visually checked the [final PNG](late.png). The page then
returned to about:blank and the owned Vite process stopped with exit 130.

[Validation](validation.json) records 224/224 tests over five named files, whole
configured Dashboard TypeScript checking and targeted ESLint exit 0. The six new
cases cover the actual parent batch, unseen loading, write success/failure,
unavailable authority and SSE GET success/failure. The fixture is outside the
TypeScript project's include paths; Vite and Chromium exercised it.

The [baseline excerpt](baseline-failure.txt) is a selected, path-redacted derivative
of the local failed log. Its header identifies the original log digest. The
original log stays in local artifacts; this excerpt does not claim byte equality.

All 34 previously parsed OCaml input hashes remain equal; parsing was not rerun.
Seven backend reaction cases remain authored and unexecuted. This run establishes
neither backend typing/execution nor durable deletion recovery, authorization
readsets, CI, installation or deployment. Issue #26378 remains open.
