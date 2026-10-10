# Approval chat projection ownership, 2026-10-09

Parent: `c4517f39133cd0c23baae70306db5ebdc719f618` (#42016).
Issue: [#41857](https://github.com/jeong-sik/masc/issues/41857).

`Keeper_approval_queue` mixed durable grant acquisition and transition authority
with chat writes, replay reconciliation, broadcasts and failed-continuation logs.
Its existing `Keeper_approval_queue_projection` already owns approval presentation
effects. Resolution, replay and continuation presentation now belong there too.
Queue authority acquires durable delivery once before passing selected readiness
to that effect owner. `Keeper_approval_queue_result` owns the pure readiness
projection and canonical continuation result type. Existing queue APIs and
constructors remain available through direct bindings and a manifest type re-export.

Rejections need no grant read. Approved replay continuations wait for both a
consumed grant and a durable replay outcome. Native instruction continuations
retain their separate admission path and Keeper ownership check: recording an
instruction receipt does not consume a tool grant or fabricate a replay outcome.
The request's stored call summary is copied, writes remain idempotent, and only
a newly appended row broadcasts or emits the failed-continuation warning.
The failed warning still precedes its broadcast.

The queue changes from 3,182 to 3,010 lines; the existing effect owner changes
from 247 to 407. [extraction-comparison.json](extraction-comparison.json) records
four byte-identical moved functions. Continuation factoring additionally requires
semantic source review and actual consumer checks; line counts are not proof.

## Consumer evidence

| Boundary | Direct consumers and executed evidence | Cases |
| --- | --- | --- |
| Resolution/replay chat effects | Existing queue scenarios: FIFO, originating Keeper, restart delivery, failed replay, reconciliation and observed/cancelled delivery | 14 |
| Stored call summary | Existing queue submission and later lifecycle rows | 1 |
| Settlement readiness and intake predicate | Existing HITL turn-start, post-tool, missing record and settled-continuation intake scenarios | 16 |
| Native instruction receipt | New standalone real-store scenario: reject another Keeper, accept before replay consumption, repeat once, preserve the unspent grant and absent replay | 1 |
| Adjacent native approval journal | Existing direct Gate wait/restart/session and refusal scenarios; this is journal evidence, not the native receipt writer test | 13 |

All 45 distinct cases passed. The three existing targets and the new standalone
target compiled successfully. [checks.json](checks.json) records commands,
terminal exit codes and executable hashes; [source-sha256.json](source-sha256.json)
records changed inputs and direct consumers. The new scenario leaves the original
Godfile test unchanged and executes no tool/provider effect.

The first direct queue invocation had one failure: its process had no
`DUNE_SOURCEROOT`, so it did not register the managed Gate replay prompt.
[queue-direct-before.log](queue-direct-before.log) preserves that result.
Running the same binary and assertions through `dune exec --no-build` supplied
the intended test environment and passed all 14 cases; see [queue.log](queue.log).
No production prompt fallback or weakened assertion was added.

## Scope

These are focused macOS compilation and isolated durable-store/chat/intake tests.
They do not establish provider execution, live Keeper continuity, visible UI,
installation, deployment, full CI or whole-stack approval. Queue locks, snapshots,
grant consumption, delivery retry and other orchestration responsibilities remain
pending in the original 171-candidate inventory. This is a bounded partial repair.
