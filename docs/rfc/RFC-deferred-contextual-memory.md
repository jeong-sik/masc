# Deferred memory and contextual consolidation

Status: implementation slices under review, 2026-10-08.

## Problem and operator decision

Persistent memory can grow while a Keeper receives unrelated shared context.
An advisory count target does not define relevance, and a category such as
`lesson` does not identify a project or task branch. Keeping every historical
detail can prevent useful consolidation, while merging by topic alone can
erase differences that matter.

The operator requested both deferred processing of stored material and deferred
retrieval, with consistency as the primary outcome. On 2026-10-08 they explicitly
changed the absorption criterion: reproducing every old sentence detail is not
important; the Librarian must distinguish duplicate knowledge, complementary
knowledge, a continuing context, replacement and an unrelated branch. Jev may
judge these relationships using who, what, when, where, why and how. These are
context cues, not six equality conditions.

This supersedes the sentence-completeness requirement of
`RFC-librarian-absorb-gate` for forward absorption. Reference validity,
preservation of meaningful conditions, original-source archival, and the
explicit distinction between `absorbs`, `supersedes` and `dropped` remain.

## Existing write boundary

Completed conversation material is already retained before asynchronous
Librarian consumption. `Keeper_librarian_durable_consumer` selects unread
durable/official ranges; failed processing does not advance the successful
memory-consumption position. The Librarian receives current memory, Keeper
instructions, task/goal context and original observations. A pending range is
not current knowledge and should not be presented as a validated memory.

Reuse this pipeline instead of introducing another competing transcript queue.
`keeper_memory_write` remains an explicit immediate write and is **not** converted
to an asynchronously acknowledged proposal by these slices. A separate deferred
write-tool contract would need a durable candidate receipt, idempotent admission,
observable pending/decided states and clear retry/unknown-outcome semantics.
Do not label that contract implemented merely because background extraction exists.

## Librarian relationship judgment

The model first identifies the applicable project, subject, task intent,
conditions, and meaningful chronology, then chooses an existing operation:

| Relationship | Operation |
|---|---|
| Same knowledge, reworded or repeatedly observed | Keep the current claim; absorb actual duplicates |
| Compatible additional conditions or knowledge in one context | Merge with `absorbs` |
| Grounded correction or changed current state | Replace with `supersedes` and a reasoned `dropped` |
| Similar topic, different subject or branch | Keep separate |
| Unresolved contradiction or missing relationship evidence | Preserve uncertainty; do not manufacture a resolution |

Categories describe the use of a memory; they are not importance scores or
proof that entries belong together. Keeper responsibilities and interests guide
what has durable value. Current-task relevance guides what is retrieved now.
These judgments must not be conflated: an infrequently retrieved operator
constraint can still be important. `last_seen` is a recording time, not authority
that a newer recorded statement describes the current world.

## Event lineage and one current record per context

The operator clarified that observations belonging to one event lineage and one
problem context should update one coherent current record, rather than accumulate
independent stage snapshots. Failure, cause discovery, workaround and resolution
may form that record when their connection is evidenced. Preserve the current
conclusion and the causal history needed to use it. Separate independent problems
within an incident; distinguish a recurrence from the original occurrence even
when their cause is shared. Similar symptoms alone do not establish lineage.
This applies to memories worth retaining, not every operational event or log.

The existing operations express this through `absorbs` for preserved contextual
knowledge and `supersedes`/`dropped` for grounded replacement. A transition record
can absorb earlier observations without reproducing incidental state values.
A current-state-only claim cannot erase the useful history by calling it absorption.
The claim-byte identity still changes on rewrite: these instructions do not implement
a stable event ID, a lineage graph, or a uniqueness constraint per context. Those
require a separate storage contract; one coherent record here is a consolidation
objective, not a newly enforced database invariant.

## Jev forward review

Each proposed absorption is evaluated with the selected pass's source observations:

```json
{
  "source_memory": "complete original memory",
  "proposed_memory": "candidate that will remain",
  "new_observations": [
    {"kind": "conversation", "batch_turn_ref": "selected batch identity", "local_position": 0,
     "text": "host-attributed conversation text"}
  ]
}
```

The runtime constructs these observations from the same selected input read by
Librarian, rather than from the generated candidate. Conversation entries retain
role and host speaker labels. `batch_turn_ref` identifies the selected batch and
is not an attribution of each observation to its final turn. `local_position` is
a zero-based position within each observation kind. Historical task-context ranges
retain their actual turn attribution and unattributed gaps in a separate
`historical_task_contexts` observation; absent attribution is never invented. Tool entries carry the host's execution outcome;
that outcome alone does not prove domain success. Counterpart content retains its
existing host-provenance rendering and remains untrusted. Hidden reasoning and
raw tool payloads remain excluded by the existing Librarian projection.

Serialized observations count toward the existing provider request boundary. If
an evidence-bearing pair cannot fit, the pass fails before dispatch and the entire
Memory range stays pending, including new claims. A typed input-capacity failure
is forwarded to the existing source-range narrowing path, allowing a smaller
range to retry against the unchanged snapshot. It does not silently omit the
evidence or append a candidate while leaving its originals unreviewed. Selecting
or splitting large evidence ranges for forward review is still future work.

The closed choices are `mergeable`, `different_context`, `loses_knowledge`, and
`uncertain`. Only `mergeable` permits that source to leave current memory.
This is not a numeric similarity threshold or the conjunction of sentence
coverage scores. Incidental receipts and repetitive examples may be omitted;
conditions, exceptions, uncertainty and meaningful causal/state transitions
must remain. Extra compatible information does not itself make preservation
of the original fail.

The Librarian owns the complete multi-source interpretation. Jev reviews each
source/candidate relationship; it does not independently verify the truth of
new assertions against the world. Every request has its own durable evaluation
record, including the new observations before provider dispatch. Invalid answers, incomplete dispatch and cancellation keep the existing
failure semantics. A pair outside the provider request boundary is explicitly
unjudgeable and its original remains current; with new observations this also
fails the pass so the candidate is not committed. Large-pair decomposition is not
implemented here.

The reverse copy question checks whether an unabsorbing new claim merely repeats
its sources. Its semantic criterion is unchanged. If its request fails, the
runtime defers the complete Memory commit, including the proposed claims. An
enabled absorb gate with a disabled lane or no armed destination likewise defers
the commit. These conditions preserve the durable input for a later retry; they
do not prove new knowledge and must not append unjudged proposals beside their
originals. Deliberately disabling the gate or excluding a Keeper still applies
the Librarian answer as configured. Pre-dispatch reverse size limitations and
intentional supersession exemptions retain their existing behavior. A gate
evaluation may be `skipped` or its forward outcome `judged` while the enclosing
Memory pass fails; consumers must use the pass commit result. Its Noul boundary is now explicitly labeled
`reverse_copy_boundary`; forward decisions are stored as categorical choices,
with original typed probabilities retained for inspection. This protects the existing Librarian range; direct `keeper_memory_write` still
needs its separate deferred candidate contract.

## Deferred read boundary

Personal recall already supports a body-free notice and query retrieval. Shared
World Curator memory now follows the same direction:

```text
default turn context -> counts + availability/freshness + retrieval route
current decision -> query -> selected claim/conflict IDs -> source detail
workspace-wide request -> explicit briefing/index retrieval
```

`keeper_workspace_memory_read` accepts one selector:

- `{}`: inventory only, no memory bodies;
- `{"query":"..."}`: up to five lexical candidates with stable IDs;
- `{"id":"..."}`: selected claim/conflict and its source resolution;
- `{"view":"briefing"}`: explicit broad synthesis with freshness;
- `{"view":"index"}`: explicit full index.

Literal and existing all-term matching cover short Korean and ASCII queries
that the trigram index cannot answer. Lexical retrieval proposes candidates;
it does not establish relevance, branch equivalence or truth. The Keeper still
judges applicability. An unavailable source is unknown, not absent. A shared
briefing is an interpretation, never approval or a replacement for current
authoritative task/goal state.

The shared briefing body is no longer injected into every default turn.
Current user input and unconsumed working context are separate from this
historical retrieval boundary and are not removed by the change.

## Deferred work still requiring a distinct implementation

1. A durable pending-candidate contract for explicit Keeper writes, if those
   writes should also wait for consolidation rather than acknowledging current memory.
2. A Keeper interest/category profile with provenance, separate from temporary
   task relevance; no count weight or popularity-derived importance.
3. Jev-assisted retrieval selection given current purpose and candidate scopes.
   The query implementation here is lexical and must not be described as that selector.
4. A coherent representation of replacement and unresolved relationships across
   personal memory and the shared Curator view, preserving original evidence.

## Validation and acceptance boundaries

A synthetic event-lineage probe of the current question matched 10 of 12 intended
admission decisions. Two same-event follow-up resolution cases were still refused,
including a held-out restoration case. Thus the instructions express the intended
policy but do not establish reliable temporal consolidation. That source/candidate-only
experiment did not carry follow-up evidence. The subsequent controlled experiment
in `experiments/memory-transition-evidence` motivates the source-observation path
above: 15/18 pair-only, 12/18 instruction-only, 18/18 with evidence. These remain
six development scenarios, not a deployed quality measurement. These refusals retain
original memories, so no memory-reduction claim follows from this experiment.


Source/runtime tests cover full-source choice dispatch, only `mergeable`
admission, failure/cancellation receipts, body-free prompt rendering, selective
retrieval, and explicit broad reads. Parsing or source review is not an executed
OCaml suite. Synthetic model evaluations test question behavior, not installed
runtime behavior or durable memory quality across hundreds of turns.

Required live follow-up: show admitted raw input and pending state, the resulting
consolidation decision and archived sources, the current snapshot, and the next
Keeper request containing only the selected relevant historical material. Report
unrelated-context injection, wrongful merge/replacement, lost constraints and
new duplicate growth separately. A lower fact count alone is not success.
