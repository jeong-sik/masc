---- MODULE MemoryCompaction ----
\* Bug Model: Memory bank compaction drops important notes.
\*
\* Models keeper_memory_bank.ml compact_memory_bank_if_needed.
\* Correct code: selection respects kind caps + fallback fill by recency.
\* Bug: priority-only selection lets high-priority long_term notes
\* fill all slots, starving goals and other kinds.
\*
\* Reference (verified 2026-07-19 — restored after collateral deletion in
\* #24332, then hardened per adversarial review; symbol refs, not line
\* numbers, per ml-line-refs gate):
\*   lib/keeper/keeper_memory_bank.ml — compact_memory_bank_if_needed entry point
\*   lib/keeper/keeper_memory_bank.ml — add_row (hard total cap + per-kind cap + dedup)
\*   lib/keeper/keeper_memory_policy.ml — kind_caps () : (memory_kind * int) list, closed-variant SSOT
\*   lib/keeper/keeper_memory_policy.ml — priority_for_kind (closed-variant priorities)
\*
\* ── Abstraction note ──
\* The real kind_caps SSOT enumerates 5 closed memory_kind constructors. This
\* model uses 4 representative kinds for the "starvation under priority-only
\* selection" invariant:
\*   goal        — {goal}      (priority 72, cap = SmallKindCap)
\*   decision    — {decision}  (priority 86, cap = SmallKindCap)
\*   progress    — {progress, open_question}
\*   long_term   — {long_term} (priority 95, only kind with cap = LongTermCap)
\* Scope of the collapse: open_question is folded into the small-cap bucket
\* ONLY because the modeled bug is long_term (>=90) monopolizing every slot —
\* which starves goals regardless of the ordering among the sub-90 kinds. The
\* collapse is therefore conservative for THIS invariant: it neither creates nor
\* hides the long_term-monopoly starvation. It does NOT model open_question's
\* own starvation vector — open_question priority is 76, ABOVE goal (72), so a
\* priority-only selection that ranked sub-90 kinds would starve goals with
\* open_questions too. That distinct vector is out of this model's scope (a
\* candidate follow-up spec), not asserted equivalent to progress here.
\* Constant abstraction: production long_term cap is 4; the model uses
\* LongTermCap = 3 (cfg). This only scales the per-kind bound, not the bug.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    TargetNotes,       \* Max notes after compaction (e.g. 8 for small model)
    SmallKindCap,      \* Max notes to keep for each ordinary kind (e.g. 2)
    LongTermCap        \* Max long_term notes to keep (e.g. 3)

VARIABLES
    bank,              \* Sequence of notes: [id |-> Nat, kind |-> "...", priority |-> Nat]
    result,            \* Sequence of notes after compaction
    phase              \* "accumulating" | "compacting" | "done"

vars == <<bank, result, phase>>

\* Kinds and their priorities (matching keeper_memory_policy.ml priority_for_kind)
Kinds == {"goal", "decision", "progress", "long_term"}

\* Count notes of a given kind in a sequence
KindCount(seq, kind) ==
    Cardinality({i \in 1..Len(seq) : seq[i].kind = kind})

\* Ids present in a sequence (notes carry a unique monotonic id so the fallback
\* fill can exclude already-selected notes — mirrors add_row's dedup by key).
IdSet(seq) == {seq[i].id : i \in 1..Len(seq)}

TypeOK ==
    /\ phase \in {"accumulating", "compacting", "done"}
    /\ \A i \in 1..Len(bank) :
         /\ bank[i].kind \in Kinds
         /\ bank[i].priority \in 0..100
         /\ bank[i].id \in Nat

Init ==
    /\ bank = <<>>
    /\ result = <<>>
    /\ phase = "accumulating"

\* ── Accumulation (add notes to bank) ──────────────────
\* Bounded just past the first compactable size (TargetNotes) so the state
\* space stays small while still admitting the starvation witness (enough
\* long_term notes to monopolize every slot alongside at least one goal).

CanAppend == phase = "accumulating" /\ Len(bank) < TargetNotes + 1

AppendNote(k, p) ==
    /\ CanAppend
    /\ bank' = Append(bank, [id |-> Len(bank) + 1, kind |-> k, priority |-> p])
    /\ UNCHANGED <<result, phase>>

AppendGoal     == AppendNote("goal", 72)
AppendDecision == AppendNote("decision", 86)
AppendProgress == AppendNote("progress", 66)
AppendLongTerm == AppendNote("long_term", 95)

\* ── Trigger compaction (when bank exceeds target) ─────

TriggerCompaction ==
    /\ phase = "accumulating"
    /\ Len(bank) > TargetNotes
    /\ phase' = "compacting"
    /\ UNCHANGED <<bank, result>>

\* ── Safe compaction (with kind caps) ──────────────────

\* First-cap of a kind: the leading notes of that kind, up to [cap].
CapKind(kind, cap) ==
    LET notes == SelectSeq(bank, LAMBDA n : n.kind = kind)
    IN SubSeq(notes, 1, IF Len(notes) > cap THEN cap ELSE Len(notes))

\* Select notes respecting per-kind caps, then fill any remaining slots from the
\* notes NOT already selected (by recency = bank order). The fallback excludes
\* already-selected ids so no note is counted twice — mirroring
\* keeper_memory_bank.ml add_row, which skips keys already in selected_keys.
SafeCompact ==
    /\ phase = "compacting"
    /\ LET
         kept_goals    == CapKind("goal", SmallKindCap)
         kept_longterm == CapKind("long_term", LongTermCap)
         kept_decisions == CapKind("decision", SmallKindCap)
         progress == SelectSeq(bank, LAMBDA n : n.kind = "progress")
         remaining == TargetNotes - Len(kept_goals)
                                  - Len(kept_longterm)
                                  - Len(kept_decisions)
         kept_progress == SubSeq(progress, 1, IF Len(progress) > remaining
                                              THEN IF remaining > 0 THEN remaining ELSE 0
                                              ELSE Len(progress))
         capped == kept_goals \o kept_longterm \o kept_decisions \o kept_progress
         \* Fallback fill (ignore kind caps to reach TargetNotes), drawing only
         \* from notes not already selected, by recency (bank order).
         selectedIds == IdSet(capped)
         notSelected == SelectSeq(bank, LAMBDA n : n.id \notin selectedIds)
         deficit == TargetNotes - Len(capped)
         extra == IF deficit > 0
                  THEN SubSeq(notSelected, 1,
                              IF Len(notSelected) > deficit THEN deficit
                              ELSE Len(notSelected))
                  ELSE <<>>
       IN
         /\ result' = capped \o extra
         /\ phase' = "done"
         /\ UNCHANGED <<bank>>

\* ── Buggy compaction (priority-only, no kind caps) ────

BugPriorityOnlyCompact ==
    /\ phase = "compacting"
    /\ LET
         \* Priority-only: the highest-priority notes (long_term, 95 >= 90) are
         \* taken first, then the rest in bank order. When long_term notes alone
         \* reach TargetNotes, every other kind — goals included — gets 0 slots.
         topPri == SelectSeq(bank, LAMBDA n : n.priority >= 90)
         lowPri == SelectSeq(bank, LAMBDA n : n.priority < 90)
         allSorted == topPri \o lowPri
         taken == SubSeq(allSorted, 1, IF Len(allSorted) > TargetNotes
                                       THEN TargetNotes
                                       ELSE Len(allSorted))
       IN
         /\ result' = taken
         /\ phase' = "done"
         /\ UNCHANGED <<bank>>

\* ── Specifications ────────────────────────────────────

NextSafe ==
    \/ AppendGoal \/ AppendDecision \/ AppendProgress \/ AppendLongTerm
    \/ TriggerCompaction
    \/ SafeCompact

NextBuggy ==
    \/ AppendGoal \/ AppendDecision \/ AppendProgress \/ AppendLongTerm
    \/ TriggerCompaction
    \/ BugPriorityOnlyCompact

Spec == Init /\ [][NextSafe]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety Invariants ─────────────────────────────────

\* After compaction, goal notes are preserved up to their cap.
\* If the bank had N goal notes, the result must have min(N, SmallKindCap).
GoalsPreserved ==
    phase = "done" =>
        KindCount(result, "goal") >=
            IF KindCount(bank, "goal") > SmallKindCap
            THEN SmallKindCap
            ELSE KindCount(bank, "goal")

\* Compaction never produces an empty result from a non-empty bank.
NeverEmpty ==
    (phase = "done" /\ Len(bank) > 0) => Len(result) > 0

\* Result never exceeds target.
ResultBounded ==
    phase = "done" => Len(result) <= TargetNotes

\* Long-term notes are preserved up to their cap.
\* Mirrors GoalsPreserved but for the long_term kind.
LongTermProtected ==
    phase = "done" =>
        KindCount(result, "long_term") >=
            IF KindCount(bank, "long_term") > LongTermCap
            THEN LongTermCap
            ELSE KindCount(bank, "long_term")

\* Completeness bound: compaction fills up to the available input, never
\* under-pruning below min(Len(bank), TargetNotes). This is NOT a recency
\* guarantee — the real recent_floor (max 16 …) never binds at this model's
\* scale (bank <= TargetNotes+1 < 16), so recency is out of scope here. It only
\* guards against a compaction that drops notes it had room to keep.
ResultNotUnderfilled ==
    phase = "done" =>
        Len(result) >= IF Len(bank) < TargetNotes
                       THEN Len(bank)
                       ELSE TargetNotes

====
