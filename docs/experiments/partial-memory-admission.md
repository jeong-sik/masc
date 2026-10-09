# Partial deferred Memory admission

## Failure being addressed

The original admission worker kept the complete batch pending when any candidate
is deferred. Its queue accepted only a contiguous consumed prefix. A candidate
whose evidence remains inconclusive therefore prevented an independent, supported
candidate later in the same batch from reaching current Memory.

The semantic question and storage question must change together. Simply allowing
a partially settled answer through the current decoder can store a claim that
combines an accepted observation with a still-deferred conjecture. Splitting the
model input into one call per candidate can hide complementary evidence about
the same event. Neither is the intended fix.

## Candidate receipt foundation

Candidate-specific receipts support one Memory transaction for a settled subset.
The sparse queue and runtime now consume those receipts. This is an unmerged
implementation; the execution status belongs to its recorded CI head.

A candidate receipt binds a queue generation, request ID, original sequence and
input digest. A set of candidate receipts is prepared and committed with one
snapshot revision and digest. Receipt insertion, snapshot effects and recovery
use the existing store lock and write-ahead protocol. A successful no-change
Memory decision also records consumption. Consumption survives later retraction
of the resulting fact; replaying a consumed candidate must not resurrect it.

Within a generation, neither request IDs nor sequences may be reused. Changing
the payload or the other identity coordinate does not create a fresh candidate.
These receipts use the existing snapshot-backed recovery policy: missing or
unverifiable current snapshot evidence invalidates receipts. They are not an
independent immutable ledger across a store reset. Retaining every consumed
candidate also grows the receipt file; no automatic expiry is introduced.

Unrelated generations have independent identities. Existing atom, official-turn
receipts retain their active contracts. Candidate receipts replace the explicit
contiguous-range path.

## Connected judgment and queue

The runtime connects these receipts to one model judgment over the whole
pending set and one disposition supported by its settled subset. The response
names the candidate dependencies of proposed changes; unknown references or
dependencies on deferred candidates cannot authorize the disposition. This is
reference validation, not proof of semantic independence.

The queue retains deferred candidates while acknowledging only exact
committed candidate receipts. It uses a persisted last-assigned sequence so
consuming later candidates does not cause sequence reuse. A concurrently appended
tail must survive. Recovery after snapshot commit and before acknowledgement
must consume exactly the committed subset, even after its output is retired.

Worker scheduling must distinguish newly appended or unevaluated input from
candidates already judged deferred. Pending input alone must not create an
immediate repeat loop. A new relevant observation can justify another judgment;
wall-clock age alone does not expire a candidate.

## Required evidence

| Scenario | Required result |
|---|---|
| A deferred, B and C settled | One snapshot transaction records only B and C consumption |
| B produces no new fact | Its candidate receipt still establishes consumption |
| Output B is later retracted | Replaying B cannot reintroduce it |
| Same request or sequence reused with changed digest | Entire transaction rejected before snapshot mutation |
| Crash between snapshot replacement and receipt finalization | Recovery recognizes all matching prepared candidate receipts |
| C appended during acknowledgement of B | C and deferred A remain present |
| A and B jointly explain one incident | Model sees both inputs and can retain their joint supported knowledge |
| A settled but proposed change declares deferred B as support | Host refuses that declared dependency; undeclared semantic dependence still needs model-quality measurement |

Injected runtime tests cover partial settlement and refusal when declared support
names a deferred candidate. Queue tests cover sparse acknowledgement and wake
behavior. These tests do not establish real-model semantic independence.

Remaining: when an actual capacity refusal forces a smaller prefix and that
prefix is entirely deferred, an unjudged suffix may still be postponed. Existing
captured model responses are replayed only if their request hashes match the
current contract; otherwise the harness records capture_not_current without
injecting the response. Schema evolution is not a new semantic success. Live
model quality and deployment remain unverified.
