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
Memory, under the configured Keeper directory. The pending snapshot has a queue
generation, acknowledged sequence and ordered candidates. A candidate retains
its request identity and complete proposed fact, including provenance and time.
Exact retry identity is recognized while pending only; it is not a permanent
operation-id ledger.

`Keeper_memory_os_current` binds a consumed explicit range to the same prepared
and committed receipt protocol as its other inputs. The range names the queue
generation, prior sequence, final sequence and digest of the complete ordered
input. A no-change Memory decision can consume candidates without rewriting the
snapshot. A later retirement does not erase the committed consumption receipt.

Under the store locks, a new range must begin at the committed frontier. Repeated,
old, overlapping and gapped ranges are refused before constructing a disposition.
Queue acknowledgement separately verifies the authoritative receipt against its
exact pending prefix. A concurrently appended tail survives acknowledgement.
Corruption is an error, not an empty queue or authorization to discard input.

## Librarian judgment

The optional `admission` argument is accepted only for a standalone
`Memory_maintenance` pass. Candidates are explicitly untrusted proposals, not
current memories or successful tool executions. The prompt asks the Librarian to
consider Keeper instructions, applicable context and event lineage. Incidental
details need not survive consolidation; distinct incidents and meaningful
exceptions must remain distinguishable.

The exact-output schema wraps the existing Memory answer in `memory`, alongside
one `candidates` judgment for every request identity:

| Outcome | Meaning | Required destination |
|---|---|---|
| `incorporated` | The Memory decision incorporates the useful knowledge | Exact final claim |
| `already_represented` | A retained Memory already carries the useful knowledge | Exact final claim |
| `not_durable` | No durable Memory is warranted | Null |
| `deferred` | Evidence is insufficient to settle the candidate | Null |

Every judgment carries a nonblank reason. Missing, duplicate or unknown request
identities reject the answer. Claim strings are exact references to the selected
destination, not a semantic similarity heuristic. Any deferred candidate leaves
the whole batch pending with no Memory or working-context effects in this slice.

The absorption judge also receives the explicitly labeled pending proposals.
Before consuming input, the store checks that all promised destinations survived
the actual disposition, support maintenance and concurrent changes. A missing
destination refuses the whole commit. Schema validity and reference integrity
do not prove semantic judgment quality.

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

The worker restores committed ranges before judging input and runs even below
the current-Memory count targets. Only the runtime's typed range-sizing signal
permits retrying a smaller prefix of whole candidates; uncertainty retains the
batch. Successful prefix consumption schedules the remaining tail. Startup
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
