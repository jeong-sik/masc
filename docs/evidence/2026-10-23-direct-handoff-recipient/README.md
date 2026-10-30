# Direct handoff waits for a reachable original request

The previous readiness query found any later unclaimed original in the queue.
If a checkpoint continuation was ahead of that original, the actual FIFO claim
selected the continuation. A direct provider turn could therefore yield to new
input while the next turn only resumed another checkpoint and yielded again.

Two native original-source demonstrations are retained separately:

| Scenario | Original result | Candidate contract |
| --- | --- | --- |
| A running; queue B checkpoint, F fresh | Readiness true | Readiness false |
| A yields under that old readiness | Next claim B, not F | No such handoff; A keeps its slot |
| A completes; B running; F now the head | Fresh can receive next slot | Readiness true, B yields, F claims |

The raw original readiness assertion is `false` expected / `true` received.
A separate original queue-order assertion is `waiting-original` expected /
`another-checkpoint` received. These are distinct assertion scenarios, not
repeated timing samples. No provider calls or actual model productivity were
measured by these store checks.

## Contract and implementation

`has_queued_handoff_recipient ~now` uses the same `claimable_queued_with_db`
selector as `claim_next`. Only a head with neither a semantic execution nor
frozen batch membership, admitted after the current running operation, can
receive an original-input handoff. Admission order uses row identity rather
than wall-clock timestamps or mutable queue sequence.

A continuation, frozen batch or older original at the head is a barrier.
Gate waits and cooling retries are skipped exactly as in the actual claim.
When a retry becomes eligible, it can become that barrier. The method performs
only reads: it changes no FIFO, manual priority, batch, checkpoint or input
identity. It is an observation, not a reservation; later cancellation, manual
priority or retry eligibility can change the eventual claim.

Both direct consumers use this contract: Agent Core's cooperative yield probe
and Codex's condition-based handoff watcher. Owner supplies its observation
clock and still wakes on durable queue publications, including count-preserving
reorders. Autonomous-to-direct readiness is unchanged. The old API is removed
from all production and test consumers; there is no compatibility wrapper, new
timer, turn/token cap or queue-priority policy.

Two existing direct tests intentionally change their earlier expectation:
fresh input behind a continuation no longer triggers a handoff. They now verify
that moving the fresh original to the actual head wakes readiness/the waiter.
This semantic change is explicit; the previous expectation is not claimed to
be unchanged behavior.

## Focused evidence

```sh
opam exec --switch=5.5.1 -- dune build test/keeper_chat_operations/test_keeper_direct_runtime_continuation.exe test/test_keeper_owner.exe
_build/default/test/keeper_chat_operations/test_keeper_direct_runtime_continuation.exe
_build/default/test/test_keeper_owner.exe test reducer 0-1
```

The candidate passes **20 Store + 2 selected Owner checks = 22**. The Owner
log's other cases are SKIP, not PASS. Controls include plain FIFO, frozen batch
barriers, original admission across repeated/rewound clocks, blocked/eligible
retry selection, older fresh input, explicit priority, recipient cancellation,
condition wakeup after a manual reorder and Owner closure. The frozen-batch
scenario also has semantic/age barriers; it does not independently isolate the
batch-membership guard.

The original production commit is `9c2256fea8fad3bb8ca7e5aed8a92cd803fcbdda`.
Reproduction cases were added before production changes. Their original exact
test-source hash was not captured. Final tests use the renamed API and explicit
observation time and add the controls above; no identical-runner claim is made.
`validation.json` binds original production, final source, commands, successful
focused counts, raw logs and the two tested executables by SHA-256.

The verified chain is Store selection -> Owner read/condition -> direct yield
probe and Codex watcher. The Store executable exercises durable transitions; the
Owner selection exercises the actual mailbox/condition consumer. Explicit
compilation also checks the production consumers. Full regression and CI were
not run. The candidate is not installed; no live latency, final task completion,
review publication, UI readiness or model-productivity improvement is claimed.
