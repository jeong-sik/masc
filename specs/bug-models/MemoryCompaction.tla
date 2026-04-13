---- MODULE MemoryCompaction ----
\* Bug Model: Memory bank compaction drops important notes.
\*
\* Models keeper_memory_bank.ml compact_memory_bank_if_needed.
\* Correct code: selection respects kind caps (constraints:2,
\* decision:2, long_term:4, ...) + recent floor (44 notes).
\* Bug: priority-only selection lets high-priority long_term notes
\* fill all slots, starving constraints and other kinds.
\*
\* Reference: keeper_memory_bank.ml lines 292-448,
\*            keeper_memory_policy.ml lines 131-148 (kind_caps).

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    TargetNotes,       \* Max notes after compaction (e.g. 8 for small model)
    ConstraintCap,     \* Max constraint notes to keep (e.g. 2)
    LongTermCap        \* Max long_term notes to keep (e.g. 3)

VARIABLES
    bank,              \* Sequence of notes: [kind |-> "...", priority |-> Nat]
    result,            \* Sequence of notes after compaction
    phase              \* "accumulating" | "compacting" | "done"

vars == <<bank, result, phase>>

\* Kinds and their priorities (matching OCaml code)
Kinds == {"constraint", "decision", "progress", "long_term"}

\* Count notes of a given kind in a sequence
KindCount(seq, kind) ==
    Cardinality({i \in 1..Len(seq) : seq[i].kind = kind})

TypeOK ==
    /\ phase \in {"accumulating", "compacting", "done"}
    /\ \A i \in 1..Len(bank) :
         /\ bank[i].kind \in Kinds
         /\ bank[i].priority \in 0..100

Init ==
    /\ bank = <<>>
    /\ result = <<>>
    /\ phase = "accumulating"

\* ── Accumulation (add notes to bank) ──────────────────

AppendConstraint ==
    /\ phase = "accumulating"
    /\ Len(bank) < TargetNotes * 2   \* Allow growth beyond target
    /\ bank' = Append(bank, [kind |-> "constraint", priority |-> 90])
    /\ UNCHANGED <<result, phase>>

AppendDecision ==
    /\ phase = "accumulating"
    /\ Len(bank) < TargetNotes * 2
    /\ bank' = Append(bank, [kind |-> "decision", priority |-> 86])
    /\ UNCHANGED <<result, phase>>

AppendProgress ==
    /\ phase = "accumulating"
    /\ Len(bank) < TargetNotes * 2
    /\ bank' = Append(bank, [kind |-> "progress", priority |-> 66])
    /\ UNCHANGED <<result, phase>>

AppendLongTerm ==
    /\ phase = "accumulating"
    /\ Len(bank) < TargetNotes * 2
    /\ bank' = Append(bank, [kind |-> "long_term", priority |-> 95])
    /\ UNCHANGED <<result, phase>>

\* ── Trigger compaction (when bank exceeds target) ─────

TriggerCompaction ==
    /\ phase = "accumulating"
    /\ Len(bank) > TargetNotes
    /\ phase' = "compacting"
    /\ UNCHANGED <<bank, result>>

\* ── Safe compaction (with kind caps) ──────────────────

\* Select notes respecting per-kind caps.
\* Priority-sorted, but each kind limited to its cap.
SafeCompact ==
    /\ phase = "compacting"
    /\ LET
         \* Constraint notes: take up to ConstraintCap
         constraints == SelectSeq(bank, LAMBDA n : n.kind = "constraint")
         kept_constraints == SubSeq(constraints, 1, IF Len(constraints) > ConstraintCap
                                                    THEN ConstraintCap
                                                    ELSE Len(constraints))
         \* Long-term notes: take up to LongTermCap
         longtermNotes == SelectSeq(bank, LAMBDA n : n.kind = "long_term")
         kept_longterm == SubSeq(longtermNotes, 1, IF Len(longtermNotes) > LongTermCap
                                                   THEN LongTermCap
                                                   ELSE Len(longtermNotes))
         \* Decision notes: take up to ConstraintCap (same cap in code)
         decisions == SelectSeq(bank, LAMBDA n : n.kind = "decision")
         kept_decisions == SubSeq(decisions, 1, IF Len(decisions) > ConstraintCap
                                                THEN ConstraintCap
                                                ELSE Len(decisions))
         \* Progress notes: fill remaining slots
         progress == SelectSeq(bank, LAMBDA n : n.kind = "progress")
         remaining == TargetNotes - Len(kept_constraints)
                                  - Len(kept_longterm)
                                  - Len(kept_decisions)
         kept_progress == SubSeq(progress, 1, IF Len(progress) > remaining
                                              THEN IF remaining > 0 THEN remaining ELSE 0
                                              ELSE Len(progress))
       IN
         /\ result' = kept_constraints \o kept_longterm \o kept_decisions \o kept_progress
         /\ phase' = "done"
         /\ UNCHANGED <<bank>>

\* ── Buggy compaction (priority-only, no kind caps) ────

BugPriorityOnlyCompact ==
    /\ phase = "compacting"
    /\ LET
         \* Just take the first TargetNotes entries (bank is appended
         \* in priority order: long_term(95) > constraint(90) > decision(86) > progress(66))
         \* So highest-priority notes fill all slots, starving lower kinds.
         \*
         \* Sort by priority descending: long_term first, then constraint,
         \* then decision, then progress.  If there are more long_term
         \* notes than TargetNotes, constraints get 0 slots.
         sortedByPri == SelectSeq(bank, LAMBDA n : n.priority >= 90)
         lowPri == SelectSeq(bank, LAMBDA n : n.priority < 90)
         allSorted == sortedByPri \o lowPri
         taken == SubSeq(allSorted, 1, IF Len(allSorted) > TargetNotes
                                       THEN TargetNotes
                                       ELSE Len(allSorted))
       IN
         /\ result' = taken
         /\ phase' = "done"
         /\ UNCHANGED <<bank>>

\* ── Specifications ────────────────────────────────────

NextSafe ==
    \/ AppendConstraint \/ AppendDecision \/ AppendProgress \/ AppendLongTerm
    \/ TriggerCompaction
    \/ SafeCompact

NextBuggy ==
    \/ AppendConstraint \/ AppendDecision \/ AppendProgress \/ AppendLongTerm
    \/ TriggerCompaction
    \/ BugPriorityOnlyCompact

Spec == Init /\ [][NextSafe]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety Invariants ─────────────────────────────────

\* After compaction, constraint notes are preserved up to their cap.
\* If the bank had N constraint notes, the result must have min(N, ConstraintCap).
ConstraintsPreserved ==
    phase = "done" =>
        KindCount(result, "constraint") >=
            IF KindCount(bank, "constraint") > ConstraintCap
            THEN ConstraintCap
            ELSE KindCount(bank, "constraint")

\* Compaction never produces an empty result from a non-empty bank.
NeverEmpty ==
    (phase = "done" /\ Len(bank) > 0) => Len(result) > 0

\* Result never exceeds target.
ResultBounded ==
    phase = "done" => Len(result) <= TargetNotes

====
