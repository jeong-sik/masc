---- MODULE SharedAudit ----
\* Cycle 19 / Tier I6 catch-up spec.
\*
\* Models the Merkle-chained immutable audit log exposed by
\* lib/shared_audit/{envelope,store}.{mli,ml}. Each entry
\* carries an id, timestamp, category, payload, and the SHA256
\* digest (prev_hash) of the previous entry's canonical JSON.
\* The chain ensures tamper detection: any modification to an
\* entry breaks the prev_hash field of the next entry, surfaced
\* via Store.verify_chain.
\*
\* The hash function is abstracted here as identity over the id
\* field — that is, hash(entry) == entry.id. This is sufficient
\* to model the chain integrity invariants because:
\*
\*   - Envelope.make generates a fresh unique id per entry, so
\*     equality of ids implies equality of entries.
\*   - The runtime SHA256 digest is collision-resistant; modelling
\*     hash via id-equality preserves chain integrity reasoning
\*     while keeping the state space small enough for TLC.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   variable                 | OCaml site
\*   -------------------------+--------------------------------------------
\*   entries                  | Store.t internal append-only list
\*   entries[i].id            | Envelope.t.id (ULID-shaped)
\*   entries[i].prev_hash     | Envelope.t.prev_hash (None for genesis,
\*                            | Some (hash_for_chain entries[i-1]) otherwise)
\*   entries[i].category      | Envelope.t.category (e.g. "RecoveryAttempted",
\*                            | "DegradationTriggered", "DeliberationTransition")

EXTENDS TLC, Naturals, Sequences, FiniteSets

CONSTANTS
    Ids,            \* finite universe of envelope ids
    Categories      \* finite universe of category strings

\* Sentinel for the genesis entry's prev_hash field — encoded as
\* a string so the [prev_hash] type stays homogeneous.
GenesisHash == "__genesis__"

Envelope == [
    id : Ids,
    category : Categories,
    prev_hash : Ids \cup {GenesisHash}
]

VARIABLES
    entries,        \* finite sequence of Envelope values
    used_ids        \* set of ids already minted (Envelope.make freshness)

vars == <<entries, used_ids>>

(* The canonical hash of an envelope is, in this model, its id.
   The runtime computes a SHA256 over canonical JSON; we abstract
   to id-equality because that is the property the chain
   integrity invariant depends on. *)
HashOf(env) == env.id

\* ── Type invariant ───────────────────────────────────────────────
TypeOK ==
    /\ \A i \in 1..Len(entries) : entries[i] \in Envelope
    /\ used_ids \subseteq Ids

\* Every minted id must appear in used_ids and at most once in
\* entries — Envelope.make guarantees freshness.
IdsUnique ==
    \A i \in 1..Len(entries) :
        \A j \in 1..Len(entries) :
            i # j => entries[i].id # entries[j].id

\* The genesis entry (entries[1]) has prev_hash = GenesisHash.
\* All later entries chain from the previous via HashOf.
ChainIntegrity ==
    /\ Len(entries) > 0 => entries[1].prev_hash = GenesisHash
    /\ \A i \in 2..Len(entries) :
            entries[i].prev_hash = HashOf(entries[i-1])

\* Every entry's id must already be in used_ids — minted before
\* (or at the moment of) appending.
EntryIdMinted ==
    \A i \in 1..Len(entries) :
        entries[i].id \in used_ids

\* ── Init / Next ──────────────────────────────────────────────────
Init ==
    /\ entries = << >>
    /\ used_ids = {}

\* Append a fresh entry with the chain-derived prev_hash.
AppendEntry(new_id, cat) ==
    /\ new_id \notin used_ids
    /\ used_ids' = used_ids \cup {new_id}
    /\ LET prev == IF Len(entries) = 0
                   THEN GenesisHash
                   ELSE HashOf(entries[Len(entries)])
       IN entries' =
            Append(entries,
                   [ id |-> new_id,
                     category |-> cat,
                     prev_hash |-> prev ])

Next ==
    \E new_id \in Ids, cat \in Categories :
        AppendEntry(new_id, cat)

Spec == Init /\ [][Next]_vars

\* State-space bound for TLC: keep the chain short enough to
\* enumerate exhaustively. Wired in via the .cfg CONSTRAINT.
BoundedEntries == Len(entries) <= 3

\* ── Bug model (RFC-Q2-8) ────────────────────────────────────────
\*
\* Models the bug class where Envelope.make computes prev_hash
\* incorrectly — uses GenesisHash for a non-genesis entry (e.g.
\* race with a concurrent appender, or a refactor that lost the
\* chain-link computation). The clean ChainIntegrity invariant
\* catches this: every i >= 2 must have prev_hash = HashOf(prev).

AppendEntryWithStaleHash(new_id, cat) ==
    /\ new_id \notin used_ids
    /\ Len(entries) > 0  \* genesis case is fine; bug is for follow-on entries
    /\ used_ids' = used_ids \cup {new_id}
    /\ entries' =
            Append(entries,
                   [ id |-> new_id,
                     category |-> cat,
                     prev_hash |-> GenesisHash ])  \* stale: should be HashOf(prev)

NextBuggy ==
    \/ Next
    \/ \E new_id \in Ids, cat \in Categories :
            AppendEntryWithStaleHash(new_id, cat)

SpecBuggy == Init /\ [][NextBuggy]_vars

THEOREM Spec => []TypeOK
THEOREM Spec => []IdsUnique
THEOREM Spec => []ChainIntegrity
THEOREM Spec => []EntryIdMinted

====
