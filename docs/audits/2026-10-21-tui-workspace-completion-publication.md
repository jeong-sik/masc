# Common workspace completion publication

This source unit follows the original verification-evidence read layer. The
full Ask/Task, preparation/discovery, Composition, held/shared-backend,
cold-input/readability/observation and matched actual Before/After goal remains
incomplete. No live Loading incident was reproduced here.

| Boundary | As-Is | To-Be in this source |
| --- | --- | --- |
| Common result | Mandatory bounded notification `Stream.add` | Session-owned terminal publication |
| No dispatch switch | UI caller delivers failure through the same queue | Original failure retained without waiting for queue capacity |
| Worker cleanup | Could wait behind completion enqueue | Retires only original unpublished registration |
| Before-entry withdrawal | No common result registration existed | Original pending registration retired; no invented outcome |
| Read/effect authority | Original scoped envelope and source admission | Same original scope and admission |
| UI collection | Finite shared prefix, then existing owned groups | Same prefix/groups, then common results in publication order |
| Session end | Shared queue belongs to session | Unclaimed common results released; late publication refused |

`Masc_tui_workspace_result` extracts the existing common launch/error/fork
contract into a real producer used by the main TUI. A unique registration is
created before dispatch. The immutable Atomic product holds pending tokens and
ready messages together. One successful CAS removes the exact pending token and
retains the original ready message/time. CAS retries contain no clock, callback,
file or logging effects. Public API exposes launch, finite batch claim and close,
not private registration/publication hooks.

Normal typed failures remain unchanged. Ordinary thrown work exceptions use the
existing boundary error; cancellation propagates without inventing success or
failure. No-switch and synchronous ordinary dispatch failure run the existing
not-run hook before forming the original error. A cancelled switch is checked
before dispatch; a job withdrawn before entry retires its own registration.
Original workspace-job cancellation and final unregister ownership are unchanged.
A closed owner starts no work, runs the existing not-run callback, and creates no
message for the ended session. Callback exceptions retain their existing behavior.

The main wrapper captures workspace/read authority before dispatch, wraps
operations as before and supplies the existing message constructor. The shared
notification queue retains its current capacity. The existing Delivery_round
still drains only its captured shared FIFO prefix, then collects a finite set of
owned results once; new shared traffic cannot extend that prefix. Existing owned
groups retain their order. Common results are appended in successful publication
order, and a paused round retains its original remainder/deadline checks.
Completions moved from shared FIFO to owned batches, so relative ordering across
sources changes. Collection is not an atomic snapshot across all producers.

UI application still checks original workspace/source/ticket/read authority and
projects admitted effect receipts separately from retired follow-up reads.
Publication is not admission, network success, work completion, physical worker
exit, key responsiveness or paint. Session close releases pending and unclaimed
messages and refuses late publication; it neither cancels workers nor retracts
already claimed round values. This is in-memory session ownership, not restart
recovery. Other producers and arbitrary work/callbacks/deliver/logging/cleanup can
still block, including on the shared queue; only the common terminal publication
wait is removed.

## Source quantities and costs

- Mandatory shared-capacity waits per common terminal delivery: 1 → 0. This is a
  source-path count, not elapsed time or observed queue occupancy.
- Shared notification capacity remains 32; no new product cap, timer, retry loop,
  cache or admission policy.
- New token/Atomic/list allocations; publication/retirement traverses actual
  pending tokens in O(P), with CAS contention/retry allocation. Batch claim
  detaches a finite ready set and reverses/maps it in O(R); integration also
  appends after existing groups. No pending scan on every idle frame.
- Ready payload retention lasts until claim/session close. Claimed round values
  remain until application/round disposal. Old workspace values still require
  admission. Costs of failed/no-start/cancelled/closed/refused reads belong in
  matched comparisons; queue-wait removal is not zero-cost delivery.
- Existing result ready timestamps and UI application-delay observations remain.
  No actual latency, memory, throughput or speedup samples were collected.

## Authored resource/protocol scenarios — unexecuted

The existing filed PNG fixture retains its real binary store/readback, operator
serialization, server workspace-precondition validation, controlled response
frames, exact response decoder, no-picture preparation and original source
admission. Two additional cases use the production common launcher, original
workspace-job lifecycle, captured protocol envelope and Delivery_round:

1. A full unrelated notification plus no dispatch switch retains the exact
   notification and filed original evidence, prevents a real file effect from
   starting, and admits the original Launch_failure to its own source.
2. A real resource read survives worker registration cleanup; a retired read
   epoch/reopened request refuses the old reply; its successor admits its own
   filed evidence. Cooperative cancellation synthesizes no terminal reply.
   Session close refuses late publication and a separate successor owner accepts
   its original result.

These cases are authored, not executed. They do not exercise an actual HTTP
network/server, full UI loop/launcher wrapper, operation receipt recovery,
logging, converter, physical overlap, screen or input. No helper-count,
UI wording/layout/row-order/snapshot/PTY assertions were added. Before-entry
withdrawal and cancelled-switch cleanup have source comparison only.

Six changed OCaml files passed parsing only, two interfaces first. Eight exact
source-preservation sections cover the original workspace-job implementation and
interface, Fetched, Types, existing owned collection, Delivery_round, protocol
read/effect admission/projection, and workspace request guard. Direct Dune
libraries are declared. Parsing is not type/warning/link/build/test evidence.
No local builds, tests, CI, native/model/controller/audio/PTY, installation,
restart, live writes, self approval or merge were performed. Independent
current-head source review and whole-stack acceptance remain separate.
