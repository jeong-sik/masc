---- MODULE KeeperMemoryLifecycle ----
\* File-system-backed keeper memory lifecycle.
\*
\* Models the bounded transition rules for short/mid/long memory across:
\*   - note capture,
\*   - overflow compaction,
\*   - generation handoff.
\*
\* Safety goals:
\*   - every persisted note has provenance,
\*   - overflow/handoff do not silently drop retained notes,
\*   - handoff clears stale short-term notes,
\*   - each tier stays within its configured bound.
\*
\* OCaml <-> TLA+ mapping (see #8642 family):
\*
\*   spec variable    | OCaml field / source                              | location
\*   -----------------+--------------------------------------------------+--------
\*   short_mem        | rows with horizon = "short_term"                 | lib/keeper/keeper_memory_policy.ml:155
\*   mid_mem          | rows with horizon = "mid_term"                   | lib/keeper/keeper_memory_policy.ml:156
\*   long_mem         | rows with horizon = "long_term"                  | lib/keeper/keeper_memory_policy.ml:157
\*   open_short       | unresolved short-term notes (open_question kind) | lib/keeper/keeper_memory_bank.ml
\*   provenanced      | rows with non-empty trace_id / source            | lib/keeper/keeper_memory_bank.ml
\*   generation       | snapshot.generation field                        | snapshot record
\*   overflowed       | derived: short_mem cardinality > MaxShort        | runtime check
\*
\* Tier vocabulary (string-typed, intentionally not a variant today):
\*   lib/keeper/keeper_memory_policy.ml:155-157
\*     `let short_term_horizon = "short_term"`
\*     `let mid_term_horizon   = "mid_term"`
\*     `let long_term_horizon  = "long_term"`
\*
\* Producer (kind -> tier classification):
\*   lib/keeper/keeper_memory_policy.ml:159-164  memory_horizon_of_kind
\*   lib/keeper/keeper_memory_policy.ml:166-175  memory_horizon_of_json
\*
\* Persistence / promotion sites:
\*   lib/keeper/keeper_memory_bank.ml:550   `let horizon = memory_horizon_of_kind kind`
\*   lib/keeper/keeper_memory_recall.ml:104 recall path uses same horizon function
\*   lib/keeper/keeper_compact_policy.ml    overflow + handoff scheduling
\*   lib/keeper/keeper_compact_audit.ml     ledger trail (provenance source)
\*
\* SCOPE DRIFT (worth knowing, NOT a spec violation):
\*   memory_horizon_of_kind silently routes unknown kinds to mid_term_horizon
\*   (lib/keeper/keeper_memory_policy.ml:164  `| _ -> mid_term_horizon`).
\*   The spec invariants (ProvenanceRequired, RecoveryBounded, NoSilentLoss)
\*   hold regardless of WHICH tier a note lands in -- the drift is UPSTREAM
\*   of the spec vocabulary. A typo'd kind ("goalss") gets the wrong tier
\*   with no signal. Tracked separately for the standard #8605 wire-string
\*   fix template (strict _opt + warn-and-default wrapper).
\*
\* Bug Model (BuggyCompactOverflow already in this spec):
\*   Clean cfg : NoSilentLoss holds (lost_notes = {}).
\*   Buggy cfg : compaction trims short tier WITHOUT promoting to mid;
\*               dropped notes accumulate in lost_notes -- NoSilentLoss
\*               MUST be violated.
\*
\* Adding new tiers / horizons:
\*   - new horizon constant -> spec needs a new tier variable + cap + invariant
\*   - new kind keyword     -> only producer side (memory_horizon_of_kind);
\*                             does NOT require spec update unless it lands
\*                             in a new tier
\*
\* Out-of-scope (intentionally not modelled here):
\*   - reward-model evaluation (lib/keeper/keeper_memory.ml include chain)
\*   - recall scoring (keeper_memory_recall.ml -- separate retrieval axis)
\*   - keeper-runtime compaction trigger thresholds (keeper_compact_policy.ml)
\*     this spec uses generic MaxShort/MaxMid/MaxLong constants instead

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxShort,
    MaxMid,
    MaxLong,
    MaxGenerations,
    MaxNotes

VARIABLES
    generation,
    next_id,
    short_mem,
    mid_mem,
    long_mem,
    open_short,
    provenanced,
    overflowed,
    lost_notes

vars ==
    << generation, next_id, short_mem, mid_mem, long_mem, open_short,
       provenanced, overflowed, lost_notes >>

AllNotes == (1..MaxNotes) \X (0..MaxGenerations)

NoteGen(note) == note[2]

CapSize(set, cap) ==
    IF Cardinality(set) < cap
    THEN Cardinality(set)
    ELSE cap

TrimToCap(set, cap) ==
    CHOOSE kept \in SUBSET set :
        Cardinality(kept) = CapSize(set, cap)

TypeOK ==
    /\ generation \in 0..MaxGenerations
    /\ next_id \in 1..(MaxNotes + 1)
    /\ short_mem \subseteq AllNotes
    /\ mid_mem \subseteq AllNotes
    /\ long_mem \subseteq AllNotes
    /\ open_short \subseteq short_mem
    /\ provenanced \subseteq (short_mem \cup mid_mem \cup long_mem)
    /\ lost_notes \subseteq AllNotes
    /\ overflowed \in BOOLEAN

Init ==
    /\ generation = 0
    /\ next_id = 1
    /\ short_mem = {}
    /\ mid_mem = {}
    /\ long_mem = {}
    /\ open_short = {}
    /\ provenanced = {}
    /\ overflowed = FALSE
    /\ lost_notes = {}

FreshNote == <<next_id, generation>>

CaptureShort ==
    /\ ~overflowed
    /\ next_id <= MaxNotes
    /\ short_mem' = short_mem \cup {FreshNote}
    /\ open_short' = open_short \cup {FreshNote}
    /\ provenanced' = provenanced \cup {FreshNote}
    /\ overflowed' = (Cardinality(short_mem') > MaxShort)
    /\ next_id' = next_id + 1
    /\ UNCHANGED <<generation, mid_mem, long_mem, lost_notes>>

CaptureMid ==
    /\ ~overflowed
    /\ next_id <= MaxNotes
    /\ mid_mem' = mid_mem \cup {FreshNote}
    /\ provenanced' = provenanced \cup {FreshNote}
    /\ overflowed' = (Cardinality(mid_mem') > MaxMid)
    /\ next_id' = next_id + 1
    /\ UNCHANGED <<generation, short_mem, long_mem, open_short, lost_notes>>

PromoteMidToLong ==
    /\ mid_mem # {}
    /\ \E note \in mid_mem :
        /\ mid_mem' = mid_mem \ {note}
        /\ long_mem' = long_mem \cup {note}
        /\ UNCHANGED <<generation, next_id, short_mem, open_short,
                        provenanced, overflowed, lost_notes>>

ResolveShort ==
    /\ open_short # {}
    /\ \E note \in open_short :
        /\ open_short' = open_short \ {note}
        /\ UNCHANGED <<generation, next_id, short_mem, mid_mem,
                        long_mem, provenanced, overflowed, lost_notes>>

TriggerOverflow ==
    /\ ~overflowed
    /\ Cardinality(short_mem) > MaxShort
    /\ overflowed' = TRUE
    /\ UNCHANGED <<generation, next_id, short_mem, mid_mem, long_mem,
                   open_short, provenanced, lost_notes>>

CompactOverflow ==
    /\ overflowed
    /\ LET
         kept_short == TrimToCap({note \in short_mem : NoteGen(note) = generation}, MaxShort)
         moved_mid == short_mem \ kept_short
         candidate_mid == mid_mem \cup moved_mid
         kept_mid == TrimToCap(candidate_mid, MaxMid)
         promoted_long == long_mem \cup (candidate_mid \ kept_mid)
       IN
         /\ short_mem' = kept_short
         /\ mid_mem' = kept_mid
         /\ long_mem' = promoted_long
         /\ open_short' = open_short \ moved_mid
         /\ overflowed' = FALSE
         /\ UNCHANGED <<generation, next_id, provenanced, lost_notes>>

Handoff ==
    /\ generation < MaxGenerations
    /\ LET
         carry_mid == mid_mem \cup short_mem
         kept_mid == TrimToCap(carry_mid, MaxMid)
         promoted_long == long_mem \cup (carry_mid \ kept_mid)
       IN
         /\ generation' = generation + 1
         /\ short_mem' = {}
         /\ mid_mem' = kept_mid
         /\ long_mem' = promoted_long
         /\ open_short' = {}
         /\ overflowed' = FALSE
         /\ UNCHANGED <<next_id, provenanced, lost_notes>>

\* Bug: overflow clears short-term state without promoting it into a durable tier.
BuggyCompactOverflow ==
    /\ overflowed
    /\ LET
         kept_short == TrimToCap({note \in short_mem : NoteGen(note) = generation}, MaxShort)
         dropped == short_mem \ kept_short
       IN
         /\ short_mem' = kept_short
         /\ mid_mem' = mid_mem
         /\ long_mem' = long_mem
         /\ open_short' = open_short \ dropped
         /\ overflowed' = FALSE
         /\ lost_notes' = lost_notes \cup dropped
         /\ UNCHANGED <<generation, next_id, provenanced>>

Next ==
    \/ CaptureShort
    \/ CaptureMid
    \/ PromoteMidToLong
    \/ ResolveShort
    \/ TriggerOverflow
    \/ CompactOverflow
    \/ Handoff

NextBuggy ==
    \/ CaptureShort
    \/ CaptureMid
    \/ PromoteMidToLong
    \/ ResolveShort
    \/ TriggerOverflow
    \/ BuggyCompactOverflow
    \/ Handoff

Fairness ==
    /\ WF_vars(CompactOverflow)
    /\ WF_vars(Handoff)

FairnessBuggy ==
    /\ WF_vars(BuggyCompactOverflow)
    /\ WF_vars(Handoff)

Spec == Init /\ [][Next]_vars /\ Fairness
SpecBuggy == Init /\ [][NextBuggy]_vars /\ FairnessBuggy

ProvenanceRequired ==
    (short_mem \cup mid_mem \cup long_mem) \subseteq provenanced

NoSilentLoss ==
    lost_notes = {}

RecoveryBounded ==
    /\ (overflowed \/ Cardinality(short_mem) <= MaxShort)
    /\ (overflowed \/ Cardinality(mid_mem) <= MaxMid)
    /\ Cardinality(long_mem) <= MaxLong

HandoffLeavesNoStaleShort ==
    \A note \in short_mem : NoteGen(note) = generation

OverflowEventuallyRecovers ==
    overflowed ~> ~overflowed

====
