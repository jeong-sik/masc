# Deferred explicit admission: transaction and judgment boundary

This branch connects ordinary observed `keeper_memory_write` calls without
`source_path` or `supersedes` to durable candidates, a standalone Librarian
admission mode and the serialized queue worker. Pending receipts acknowledge
the saved input, not current Memory admission. This is not a deployed feature.

The measured baseline is [explicit-memory-admission-growth.md](explicit-memory-admission-growth.md).
The same rule with a different observation number grew to 200 current facts;
exact reobservations stayed at one fact. Independent rules also stayed distinct.
Admission must improve the former without erasing the latter.

## Authority and recovery

`Keeper_memory_admission_queue` stores candidate facts separately from current
Memory, under the configured Keeper directory. The pending snapshot has a queue generation, last-assigned sequence and ordered
candidates. Gaps are valid after partial settlement; append never reuses consumed
sequence numbers. A candidate retains its request identity and proposed fact,
including provenance and time. Exact retry identity is recognized while pending
only; it is not a permanent operation-id ledger.

`Keeper_memory_os_current` binds settled candidate identities to one prepared and
committed snapshot transaction. Each identity contains the queue generation,
request ID, original sequence and digest of its exact candidate row. A no-change
decision can consume candidates without rewriting the snapshot. Later retirement
does not erase consumption against a valid successor snapshot. Receipt recovery
remains snapshot-backed; store reset or unverifiable snapshot evidence is not an
independent immutable-ledger guarantee.

Under store locks, consumed request IDs or sequence numbers cannot be reused in
the same generation. Queue acknowledgement verifies every colliding receipt
against the exact pending payload before a single rewrite. Only matching
candidates disappear; deferred gaps and concurrently appended tails survive.
Malformed queue state is an error, not empty state or permission to discard input.

## Librarian judgment

The optional `admission` argument is accepted only for a standalone
`Memory_maintenance` pass. Candidates are explicitly untrusted proposals, not
current memories or successful tool executions. The prompt asks the Librarian to
consider Keeper instructions, applicable context and event lineage. Incidental
details need not survive consolidation; distinct incidents and meaningful
exceptions must remain distinguishable.

The exact-output schema wraps the existing Memory answer in `memory`, alongside
one `candidates` judgment for every request identity and `change_support` request IDs:

| Outcome | Meaning | Required destination |
|---|---|---|
| `incorporated` | The Memory decision incorporates the useful knowledge | Exact final claim |
| `already_represented` | A retained Memory already carries the useful knowledge | Exact final claim |
| `not_durable` | No durable Memory is warranted | Null |
| `deferred` | Evidence is insufficient to settle the candidate | Null |

Every judgment carries a nonblank reason. Missing, duplicate or unknown request
identities reject the answer. Claim strings are exact references to the selected
destination, not a semantic similarity heuristic. A deferred candidate remains pending while independently settled candidates can
be consumed. The model still sees all candidates together. Its one Memory
disposition must depend only on current Memory and settled evidence. Declared
support must be unique and known, with incorporated/already-represented outcomes;
mutations require support and every new claim must name an incorporated
supporting candidate. A declaration naming deferred or not-durable evidence is
refused. This validates references, not completeness of semantic dependencies.

The absorption judge receives only the explicitly labeled supporting proposals.
Before consuming input, the store checks that all promised destinations survived
the actual disposition, support maintenance and concurrent changes. A missing
destination refuses the whole commit. Schema validity and reference integrity
do not prove semantic judgment quality.

## Pending observations after retirement

A pending candidate has not yet acquired a consumed-input receipt. Receipt
validation prevents replay of an already consumed candidate, but cannot decide whether a
first-time candidate has become obsolete while waiting:

| Order | Current Memory | Pending candidate |
|---|---|---|
| N | A: production policy P-42 requires one approval | A is proposed again |
| N+1 | A is explicitly retracted with a policy-withdrawal reason | Candidate remains durable |
| N+2 | A is absent | Librarian evaluates the original candidate |

The admission prompt now supplies committed removal evidence for candidate
identities found in the dropped archive. It includes the removal time, revision,
producer and reason, tied to the candidate request ID. Only exact Memory identity
matches are projected; unrelated archived claim bodies are not injected. This
adds evidence for the Librarian to distinguish an old observation from a new
observation supporting reintroduction. It does not automatically reject either.
Removal reasons and candidate text remain data, not instructions or restoration
authority. A journal read failure is explicitly unavailable evidence, not a claim
that no retirement occurred.

This is a prompt-evidence boundary, not a concurrency guard or a semantic lineage
resolver. Paraphrased candidates with different identities are not connected by
this lookup. An archive entry requires an explicit removal reason; an empty
lookup does not prove a memory was never removed. Later re-additions and current
identities are excluded by the archive reader. A removal after prompt construction
is not captured by this read. Model quality and these remaining lifecycle cases
require separate measurement.

## Evidence and remaining work

Foundation run [37806167134](https://github.com/jeong-sik/masc/actions/runs/37806167134)
at `a9ec7a9a1e8d0b6d2aa75d90ee74ab7d519dcff8` passed 93 current-store and four
queue tests. Later judgment/runtime changes are outside that execution result.

Connected producer run [37810272063](https://github.com/jeong-sik/masc/actions/runs/37810272063)
at `03c63c6de89bd34838d9dd85b01f96c2a1b33c49` passed 228 tests: judgment5,
write67, supersedes14, dispatch118, CLI-lane23 and growth1. Earlier worker run
37808773842 passed queue8, Memory-lane18, boot-reconcile29 and store-scope7,
alongside CLI23; its one judgment-fixture failure was repaired by checking
nested extra fields at the strict runtime decoder boundary.
The runtime fixtures use an injected exact-lane runner, not a live provider or
CLI subprocess.

The worker acknowledges committed candidates before judging input and runs even below
the current-Memory count targets. Only the runtime's typed range-sizing signal
permits splitting into smaller whole-candidate parts. Successful consumption
schedules only newly appended input, not already-evaluated deferred gaps.
An actual size refusal permits disjoint whole-candidate halves. A completed
semantic deferral or indivisible size refusal preserves that slice and continues
its unjudged sibling. Provider, schema, dispatch and store failures stop traversal.
The worker never retries the same deferred slice within a pass. If new input
arrives while no candidate commits, a separate recheck outcome schedules it
without claiming a commit. Each sibling judgment reads fresh current Memory;
capacity partitioning itself does not prove semantic independence. Startup
also discovers candidate-only files, retaining them if Keeper metadata is absent.
Whole-Keeper purge owns the queue; checkpoint purge does not discard it.

Source-bound writes, derived facts and superseding writes still use the existing
current-store path and need their own admission semantics. The pending receipt
returns a request ID and sequence but no current Memory identity or revision.
Those scheduling fields do not count as a changed semantic tool answer. Each new
tool call creates a new candidate; there is no permanent cross-call retry ledger.
A failed pending save has an unknown effect and names its request ID. Searching
current Memory cannot prove that no pending input was saved.

After admission, search current Memory for a supported premise identity. The
existing explicit-supersedes authorship check still applies; a Librarian-generated
injected claim is not thereby made an authored supersession target. Validate semantic retention with the three baseline cohorts, then
measure actual Keeper prompts and continuity after deployment.
