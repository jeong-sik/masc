# Code reading return

Issue #43914. This increment extends the file finder with continuous reading
across B returns; it does not complete the wider music and nonmusic TUI goal.

The original B handler popped history and replaced scope/directory before a
read completed. Reloading also reused the cursor line as the scroll top and
discarded horizontal position. The new immutable jump record stores all three
position axes and tree selection/focus. A separate pending return keeps the
current file and history intact. Successful content is committed only under
the original file, scope, directory, workspace/read authority and exact history
owner. The destination's own scope and expected workspace bind its HTTP read.

Actual input precedes deferred success; repeated B shares a pending return.
Failure and cancellation leave the history entry available. A current readable
file and a tree-only destination can return immediately. A changed destination
clamps saved positions to its new dimensions. The arbitrary twenty-entry
truncation was removed so return history is not silently discarded.

The existing workspace-entries suite adds request/state scenarios for successful
return, same-path retry and cancellation, changed authority/view/source/history,
content clamping and tree-only return. These are not screen wording, ordering or
layout assertions. Changed OCaml source parsing and whitespace checks passed.
No local Dune build was run. Compilation, executed tests, actual candidate UI,
independent source review, approval and integration remain separate stages.

## Late ordinary-read review response

A second independent review found a P2 at lower `cb87e2608342c8b8b8ec5c397f4e4efeada59b77`
and upper `6618d8ba8eb0acb1caa2e7fde1402968ddd39446`. Fetched can expose Ready
while a same-key ordinary Open read is still pending. B's fast return could
restore position, then accept that earlier read and reset position/focus again.
The earlier PASS is superseded for readiness of those sources.

The response retires pending file reply admission before an actual return,
including non-Ready return paths, and restores Refresh resume intent. The
Fetched transition retains completed Ready/Stale observations and existing
failure causes. It publishes no new read result and does not claim physical
worker cancellation. Late Ok/Error callbacks cannot reset the returned reading.
Production state regressions cover Ready, Stale and first-read owners, late
callbacks, no added same-file read and authority recovery intent. The response
agent executed the actual Fetched/Alcotest source standalone: eight checks
passed without Dune. The Code production state additions remain unexecuted at
this response. Existing candidate executions certify only their original SHA.
