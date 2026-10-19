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
