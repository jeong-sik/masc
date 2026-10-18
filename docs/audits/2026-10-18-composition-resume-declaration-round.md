# Composition continuation declaration preparation

Source baseline: `0f42770b1664aadc71ddd35967193b8da994fe97`.
Scope: declaration preparation for independently ready original Composition runs
in one maintenance pulse, plus fresh explicit continuation intake.

| Boundary | Before | After |
| --- | --- | --- |
| `N` eligible ready intakes in one pulse | Each intake discovers and indexes all Keeper declarations | First demand acquires one immutable projection shared by those intakes |
| All candidates active or held | No intake declaration read | Still no declaration read |
| Declaration read in an intake fiber | Direct filesystem discovery/parsing | Common I/O executor submission and its existing inline policy |
| Edit after the first intake's acquisition | Later intakes can capture another declaration projection | Same pulse uses the captured projection; a later pulse captures anew |
| Parse/instruction/name/duplicate errors | Each intake independently discovers the failure | Each Keeper's typed failure stays in the shared projection; no empty defaults |
| Explicit resume after a pulse | Fresh declaration read | Fresh declaration read; no supervisor cache |
| Original run, Task, owner and admission | Per-intake exact original evidence and durable owner/node admission | Same per-intake authority; a shared projection cannot authorize another run |

For a non-cancelled pulse with `N > 0` eligible intakes, the source path for
full declaration discovery changes from `N` acquisitions to one. For no eligible
intakes it remains zero. These are source dependency counts, not measured file
operations, allocations, model-start latency or speedup. Cancellation may restart
an interrupted read for a remaining caller after common executor cleanup; this
is read-only preparation, never a replay of job effects.

The projection belongs to the pulse's closure, not the supervisor or process.
`Eio.Lazy` shares both an in-flight acquisition and its immutable result. Each
intake still reads its Keeper metadata and published Skill context, loads the
original activation/Task evidence, and enters the existing durable admission.
Explicit public resume creates its own fresh projection. No freshness interval,
TTL, new runtime cap or cross-pulse cache is introduced. The pool-absent,
already-worker and non-Eio inline policies remain common executor behavior.

Two feature scenarios are authored and unexecuted. They prepare two real
original runs waiting on the same owned job, collect its canonical result, then
use production discovery/scheduling and real declaration files with controlled
intake outcomes. An edit after the first intake must not split the pulse's
projection; the next pulse must observe it. The failure variant must retain
typed parse errors through the pulse and see repair in the next one. Both also
check that explicit resume sees a subsequent malformed declaration, original
request/Task identities survive, and projection reads do not touch the job
backend. Existing held-owner and authority-refusal scenarios use the expanded
controlled-intake signature.

Parser-only checks cannot prove typing, concurrent worker acquisition,
cancellation cleanup, actual model/tool execution, TUI rendering or latency.
Matched runtime comparison should retain the original run/request/Task,
declaration dataset and eligible cohort size, recording preparation-to-model
start and first useful work separately. Keep failed, cancelled, interrupted and
unfinished samples. No installed binary, runtime or painted-UI improvement is
claimed by this source change.

Remaining original scope includes typed Composition authority-hold recovery,
Ask-answer-to-original-Task useful-work continuity, further demonstrated
preparation duplication, remaining synchronous TUI editor operations and complete
matched Before/After observations. Dynamic dependency-ready Composition
scheduling and per-pulse shared backend presence inventory already exist; this
change does not implement or claim them anew.
