# Deferred explicit admission: transaction and judgment boundary

This branch implements the durable candidate store and a standalone Librarian
admission mode. Ordinary `keeper_memory_write` still writes current Memory.
The queue worker, startup discovery and write-tool pending receipts are not yet
connected. This is not a deployed deferred-write feature.

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
The runtime fixtures use an injected exact-lane runner, not a live provider or
CLI subprocess.

Before enabling deferred writes, connect the write receipt, serialized worker,
startup recovery, purge ownership and capacity-driven batch handling. Explicit
source-bound writes, derived facts and superseding writes need their own admission
semantics. Validate semantic retention with the three baseline cohorts, then
measure actual Keeper prompts and continuity after deployment.
