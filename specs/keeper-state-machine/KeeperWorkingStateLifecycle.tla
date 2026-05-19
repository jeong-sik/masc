---- MODULE KeeperWorkingStateLifecycle ----
\* Keeper working-state lifecycle for active operational loops.
\*
\* This spec covers the layer that KeeperMemoryLifecycle intentionally does
\* not model: the short-lived but durable "what am I still responsible for?"
\* state that must survive prompt compaction, handoff, and resume.  Examples
\* include an opened PR awaiting CI/review, a claimed task awaiting verification,
\* or a runtime investigation with a concrete next action.
\*
\* The model is not a workflow prescription.  The keeper remains free to choose
\* the next action; the safety contract is only that unresolved obligations stay
\* structurally present until resolved with evidence.
\*
\* OCaml ↔ TLA+ mapping (symbol-anchored):
\*
\*   spec variable       | OCaml / runtime source                              | semantic
\*   --------------------+-----------------------------------------------------+---------------------------
\*   active_loops        | future Keeper_working_state.active_loops           | unresolved obligations
\*   resolved_loops      | future Keeper_working_state.resolved_loops         | resolved but not archived
\*   archived_loops      | future Keeper_working_state.archived_loops         | compacted durable history
\*   prompt_digest       | keeper_turn prompt continuity / working_context    | bounded pre-turn summary
\*   evidence_refs       | tool/result refs, PR ids, trace ids, receipt ids   | proof that loop exists
\*   resolution_refs     | CI/review/verifier/merge/close evidence refs       | proof that loop is done
\*   who/what/when/...   | structured open-loop payload fields                | 6W-style minimum metadata
\*   lost_active         | audit-only counterexample bucket                   | must stay empty
\*
\* Relation to existing specs:
\*   - KeeperCompactionLifecycle.tla models phase alignment.
\*   - KeeperMemoryLifecycle.tla models short/mid/long note promotion.
\*   - This spec models active-loop preservation across compact/handoff.
\*
\* Bug Model:
\*   Clean cfg : active loops remain in prompt_digest and are never moved to
\*               lost_active without resolution evidence.
\*   Buggy cfg : compaction can drop an active loop, or handoff can omit active
\*               loops from the digest.  ActiveLoopsNoSilentLoss and
\*               PromptDigestCoversActive MUST be violated.

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxLoops,
    MaxActive,
    MaxDigest,
    MaxArchived

ASSUME
    /\ MaxActive <= MaxDigest
    /\ MaxDigest <= MaxLoops
    /\ MaxArchived <= MaxLoops

VARIABLES
    next_id,
    active_loops,
    resolved_loops,
    archived_loops,
    prompt_digest,
    evidence_refs,
    resolution_refs,
    who_refs,
    what_refs,
    when_refs,
    where_refs,
    why_refs,
    how_refs,
    compacted,
    handed_off,
    lost_active

vars ==
    << next_id, active_loops, resolved_loops, archived_loops, prompt_digest,
       evidence_refs, resolution_refs, who_refs, what_refs, when_refs,
       where_refs, why_refs, how_refs, compacted, handed_off, lost_active >>

AllLoops == 1..MaxLoops

KnownLoops == active_loops \cup resolved_loops \cup archived_loops

CapSize(set, cap) ==
    IF Cardinality(set) < cap
    THEN Cardinality(set)
    ELSE cap

TrimToCap(set, cap) ==
    CHOOSE kept \in SUBSET set :
        Cardinality(kept) = CapSize(set, cap)

DigestFor(active, resolved) ==
    active \cup TrimToCap(resolved, MaxDigest - Cardinality(active))

TypeOK ==
    /\ next_id \in 1..(MaxLoops + 1)
    /\ active_loops \subseteq AllLoops
    /\ resolved_loops \subseteq AllLoops
    /\ archived_loops \subseteq AllLoops
    /\ prompt_digest \subseteq (active_loops \cup resolved_loops)
    /\ evidence_refs \subseteq AllLoops
    /\ resolution_refs \subseteq AllLoops
    /\ who_refs \subseteq AllLoops
    /\ what_refs \subseteq AllLoops
    /\ when_refs \subseteq AllLoops
    /\ where_refs \subseteq AllLoops
    /\ why_refs \subseteq AllLoops
    /\ how_refs \subseteq AllLoops
    /\ lost_active \subseteq AllLoops
    /\ Cardinality(active_loops) <= MaxActive
    /\ Cardinality(prompt_digest) <= MaxDigest
    /\ Cardinality(archived_loops) <= MaxArchived
    /\ compacted \in BOOLEAN
    /\ handed_off \in BOOLEAN

Init ==
    /\ next_id = 1
    /\ active_loops = {}
    /\ resolved_loops = {}
    /\ archived_loops = {}
    /\ prompt_digest = {}
    /\ evidence_refs = {}
    /\ resolution_refs = {}
    /\ who_refs = {}
    /\ what_refs = {}
    /\ when_refs = {}
    /\ where_refs = {}
    /\ why_refs = {}
    /\ how_refs = {}
    /\ compacted = FALSE
    /\ handed_off = FALSE
    /\ lost_active = {}

FreshLoop == next_id

CanCaptureLoop ==
    /\ next_id <= MaxLoops
    /\ Cardinality(active_loops) < MaxActive

CaptureLoop ==
    /\ CanCaptureLoop
    /\ active_loops' = active_loops \cup {FreshLoop}
    /\ prompt_digest' = DigestFor(active_loops', resolved_loops)
    /\ evidence_refs' = evidence_refs \cup {FreshLoop}
    /\ who_refs' = who_refs \cup {FreshLoop}
    /\ what_refs' = what_refs \cup {FreshLoop}
    /\ when_refs' = when_refs \cup {FreshLoop}
    /\ where_refs' = where_refs \cup {FreshLoop}
    /\ why_refs' = why_refs \cup {FreshLoop}
    /\ how_refs' = how_refs \cup {FreshLoop}
    /\ compacted' = FALSE
    /\ handed_off' = FALSE
    /\ next_id' = next_id + 1
    /\ UNCHANGED <<resolved_loops, archived_loops, resolution_refs,
                    lost_active>>

ResolveLoop ==
    /\ active_loops # {}
    /\ \E loop \in active_loops :
        /\ active_loops' = active_loops \ {loop}
        /\ resolved_loops' = resolved_loops \cup {loop}
        /\ resolution_refs' = resolution_refs \cup {loop}
        /\ prompt_digest' = DigestFor(active_loops', resolved_loops')
        /\ compacted' = FALSE
        /\ handed_off' = FALSE
        /\ UNCHANGED <<next_id, archived_loops, evidence_refs, who_refs,
                        what_refs, when_refs, where_refs, why_refs, how_refs,
                        lost_active>>

ArchiveResolvedLoop ==
    /\ resolved_loops # {}
    /\ \E loop \in resolved_loops :
        /\ resolved_loops' = resolved_loops \ {loop}
        /\ archived_loops' = TrimToCap(archived_loops \cup {loop}, MaxArchived)
        /\ prompt_digest' = DigestFor(active_loops, resolved_loops')
        /\ compacted' = FALSE
        /\ handed_off' = FALSE
        /\ UNCHANGED <<next_id, active_loops, evidence_refs, resolution_refs,
                        who_refs, what_refs, when_refs, where_refs, why_refs,
                        how_refs, lost_active>>

CompactWorkingState ==
    /\ prompt_digest' = DigestFor(active_loops, resolved_loops)
    /\ compacted' = TRUE
    /\ handed_off' = FALSE
    /\ UNCHANGED <<next_id, active_loops, resolved_loops, archived_loops,
                    evidence_refs, resolution_refs, who_refs, what_refs,
                    when_refs, where_refs, why_refs, how_refs, lost_active>>

HandoffWorkingState ==
    /\ prompt_digest' = DigestFor(active_loops, resolved_loops)
    /\ compacted' = FALSE
    /\ handed_off' = TRUE
    /\ UNCHANGED <<next_id, active_loops, resolved_loops, archived_loops,
                    evidence_refs, resolution_refs, who_refs, what_refs,
                    when_refs, where_refs, why_refs, how_refs, lost_active>>

ResumeFromDigest ==
    /\ compacted \/ handed_off
    /\ active_loops \subseteq prompt_digest
    /\ compacted' = FALSE
    /\ handed_off' = FALSE
    /\ UNCHANGED <<next_id, active_loops, resolved_loops, archived_loops,
                    prompt_digest, evidence_refs, resolution_refs, who_refs,
                    what_refs, when_refs, where_refs, why_refs, how_refs,
                    lost_active>>

\* Bug: compaction summarizes around an active loop and records it as lost.
BuggyCompactDropsActive ==
    /\ active_loops # {}
    /\ \E dropped \in active_loops :
        /\ active_loops' = active_loops \ {dropped}
        /\ lost_active' = lost_active \cup {dropped}
        /\ prompt_digest' = DigestFor(active_loops', resolved_loops)
        /\ compacted' = TRUE
        /\ handed_off' = FALSE
        /\ UNCHANGED <<next_id, resolved_loops, archived_loops, evidence_refs,
                        resolution_refs, who_refs, what_refs, when_refs,
                        where_refs, why_refs, how_refs>>

\* Bug: handoff keeps the loop in storage but omits it from the bounded digest.
BuggyHandoffOmitsActiveDigest ==
    /\ active_loops # {}
    /\ prompt_digest' = TrimToCap(resolved_loops, MaxDigest)
    /\ compacted' = FALSE
    /\ handed_off' = TRUE
    /\ UNCHANGED <<next_id, active_loops, resolved_loops, archived_loops,
                    evidence_refs, resolution_refs, who_refs, what_refs,
                    when_refs, where_refs, why_refs, how_refs, lost_active>>

Next ==
    \/ CaptureLoop
    \/ ResolveLoop
    \/ ArchiveResolvedLoop
    \/ CompactWorkingState
    \/ HandoffWorkingState
    \/ ResumeFromDigest

NextBuggy ==
    \/ CaptureLoop
    \/ ResolveLoop
    \/ ArchiveResolvedLoop
    \/ BuggyCompactDropsActive
    \/ BuggyHandoffOmitsActiveDigest
    \/ ResumeFromDigest

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

LifecycleDisjoint ==
    /\ active_loops \cap resolved_loops = {}
    /\ active_loops \cap archived_loops = {}
    /\ resolved_loops \cap archived_loops = {}

WorkingLoopsHaveSixWAndEvidence ==
    /\ KnownLoops \subseteq evidence_refs
    /\ KnownLoops \subseteq who_refs
    /\ KnownLoops \subseteq what_refs
    /\ KnownLoops \subseteq when_refs
    /\ KnownLoops \subseteq where_refs
    /\ KnownLoops \subseteq why_refs
    /\ KnownLoops \subseteq how_refs

ResolvedOnlyWithResolutionEvidence ==
    (resolved_loops \cup archived_loops) \subseteq resolution_refs

ActiveLoopsNoSilentLoss ==
    lost_active = {}

PromptDigestBounded ==
    Cardinality(prompt_digest) <= MaxDigest

PromptDigestCoversActive ==
    active_loops \subseteq prompt_digest

CompactionPreservesActive ==
    compacted => active_loops \subseteq prompt_digest

HandoffCarriesActive ==
    handed_off => active_loops \subseteq prompt_digest

====
