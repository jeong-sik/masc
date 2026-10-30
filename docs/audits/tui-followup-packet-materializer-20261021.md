# Original follow-up packet materialization

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Packet preparation | Manual file copy and SHA256 entry | Explicit path plan freezes bytes and generates v2 artifact declarations |
| Cohort ownership | Original selected instances/roster supplied | Same independent declarations retained, without success/event-based discovery |
| File authority | Strict pinned descriptor reads only in report | The same reader supplies both materialization and digest verification |
| Existing output | Reader refuses existing report files | Materializer also atomically reserves a new directory and uses exclusive files |
| Damaged/missing source | Caller must retain original context | Original plan, copied evidence, errors and available validation attempts retained; no ready packet |

The materializer is a separate offline CLI. It does not start TUI/server/provider,
read unlisted input artifacts, install or execute captured artifacts. Conditions are explicit
input files or unknown nulls, not current machine or reported-version guesses.
Their byte hashes do not prove those inputs governed an original execution.
Original selected instances, supplied attempts and declared source commit remain
caller declarations. Packet v2 and existing all-outcome/missing-stage semantics
are unchanged. Source/admission capture and all TUI code are unchanged.

The existing artifact reader exposes its original stable/no-symlink regular-file
byte read; digest-verifying report reads use that same code. Within one invocation,
each explicit source path is captured once and content-identical bytes share one
copied blob. Input arrays are preserved, so duplicate/foreign/malformed evidence
is still rejected by the original analyzer rather than silently deduplicated.
Output overlap is refused; lexical input authority remains the original rooted
descriptor path, not the normalized overlap-check path.

A new private directory and exclusive files avoid replacing an existing result.
The original plan is retained before validation. Input errors preserve known
cohort slots through the plan, plus all available reader facts in validation JSON;
preparation errors disable comparisons and withhold a ready packet. Output I/O
failure can leave partial artifacts or a missing receipt and returns failure.
Individually stable reads are not a simultaneous workspace/cohort snapshot.

Costs include source reads/hashes, copied bytes/disk, validation rereads, JSON and
cohort union memory. The preparation receipt has its own Python monotonic span
before receipt serialization/write. It is not added to TUI admission/worker/UI
clocks and is not a full cold-start duration. No fsync, complete-capture witness,
source/binary/install execution identity, useful Task work, paint or speedup is
proved by byte hashes or a materialized status.

One existing actual canonical Ask/answer/Task/frame/store resource case is extended,
unexecuted. Original filtered/unstarted/complete observations reach the public
materializer and report. Real source mutation cannot replace frozen output;
existing output is refused; damaged source keeps the original plan and journaled
denominator in failed validation without publishing a packet. Corruption of the
actual copied log artifact still yields the original reader's error and denominator.
The original canonical Task resources remain unchanged. No helper-count, wording,
layout/snapshot/PTY tests were added.

Validation is Python AST parsing for two files and OCaml parsing for the one
resource scenario, plus source/diff inspection. No CLI/import/test/build/typecheck,
CI, native/model/controller/audio/PTY run, install/restart/live writes, delegation,
approval or merge. All six objective axes and actual matched Before/After stay open.
