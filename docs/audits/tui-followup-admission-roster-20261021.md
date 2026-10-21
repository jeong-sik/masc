# Original Ask follow-up admission capture

| Boundary | As-Is | To-Be in this source |
|---|---|---|
| Independent denominator | Caller supplies every original attempt | Production also records original admission identities before dispatch |
| Filtered Info | No event from which to recover the attempt | Admission journal bypasses log severity; an absent event remains unobserved |
| Comparison inputs | Declared roster plus daily logs | Packet v2 unions declared roster, hashed admission artifacts and daily logs |
| Artifact damage | Known supplied attempts survive | Known supplied and valid journaled attempts survive unrelated log damage |
| Store ownership | Main discards initialized directory | Opaque initialized store belongs to original TUI state across workspace changes |

The existing store initializes a private unique session, plus an empty
`admissions/ask-followup.jsonl`. Main retains its opaque owner and records the
original process/request/admission-clock tuple immediately after capturing the
read, before started/worker/dispatch. Immutable origin retains its original
instance string alongside the unchanged cached JSON. No decoding or current
replacement state supplies identity. Failed, unstarted, cancelled, withdrawn
and unfinished reads use the same admission path without outcome selection.

Recording reuses `Fs_compat.append_jsonl`, including its existing path mutex,
writer cache and flush. No new backend, timer, retry, environment knob, authority
gate or per-attempt in-memory registry. Expected filesystem failures return Error
and emit a best-effort warning; Main continues observation. Unexpected exceptions
and cancellation are not converted into success. This roster is independent of
filtered event logs, not an external execution witness or capture certificate.

The strict reader reuses its pinned, no-symlink, regular/stable SHA256 artifact
reader for admission files. It preserves row references, rejects unsupported
rows and duplicate admitted identities, and unions all known attempts. A read
without events remains unobserved, without a fabricated worker, cause or dispatch.
Evidence errors disable descriptive comparison. Matching bytes/conditions still
do not verify execution/source/binary/install identity or a complete denominator.

## Costs and verification limits

Setup creates one directory and empty file. Every admission encodes one identity,
takes the existing append lock and flushes. These synchronous preparation costs
follow the original admission clock; subsequent started/worker/UI intervals include
them. Flush is not fsync. Data grows with admitted reads; no numeric behavior or
retention cap was introduced. Failure/interruption can leave unknown identities,
so the independent supplied roster remains useful. Missing attempts are never
filled from successful reads. No CPU/Loading/input/elapsed improvement is measured.

Two existing actual canonical Ask/answer/Task/frame/result/store cases are extended,
unexecuted. One filters actual Info emission while the production admission file
retains a read omitted from the supplied roster; copied hashed artifacts reach
the public offline CLI and retain known attempts after real log-file mutation.
Another uses a real directory blocker at the admission-file path, requires a
recording Error and retains original Task/read behavior. These are same-process
resource/protocol scenarios, not live network, Main key loop, paint, multi-process
or performance evidence. No helper-count, wording/layout/snapshot/PTY tests added.

Interfaces were changed first. Validation is OCaml parsing and Python AST parsing
only, plus source/diff inspection. No typecheck/build/test/CLI execution, CI,
native/model/controller/audio/PTY run, install/restart/live write, approval or
merge. All six objective axes and actual matched Before/After remain open.
