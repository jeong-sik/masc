---- MODULE MemoryCompaction ----
\* Bug Model: Memory bank compaction drops important notes.
\*
\* Models keeper_memory_bank.ml compact_memory_bank_if_needed.
\* Correct code: selection respects kind caps + recent floor.
\* Bug: priority-only selection lets high-priority long_term notes
\* fill all slots, starving goals and other kinds.
\*
\* Reference (verified 2026-04-20):
\*   lib/keeper/keeper_memory_bank.ml:346
\*       compact_memory_bank_if_needed entry point
\*   lib/keeper/keeper_memory_bank.ml:296
\*       memory_kind_caps_for_compaction (per-target cap derivation)
\*   lib/keeper/keeper_memory_policy.ml:kind_caps
\*       kind_caps () : (memory_kind * int) list — closed-variant SSOT
\*
\* ── Abstraction note ──
\* The real kind_caps SSOT enumerates 5 closed memory_kind constructors,
\* rendered canonically on the wire as:
\*   decision:2, goal:2, progress:2, open_question:2, long_term:4
\* This bug model collapses them to 4 representative kinds for the
\* "starvation under priority-only selection" invariant:
\*   goal        — collapses {goal}
\*   decision    — collapses {decision}
\*   progress    — collapses {progress, open_question}
\*                 (all per-cap=2 generic notes)
\*   long_term   — collapses {long_term} (only kind with cap=4)
\* Two abstract caps (SmallKindCap, LongTermCap) are sufficient to
\* express the bug because the asymmetry that causes starvation is
\* between "the high-priority kind" (long_term) and "the small-cap
\* kinds" (everything else with cap=2).

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    TargetNotes,       \* Max notes after compaction (e.g. 8 for small model)
    SmallKindCap,      \* Max notes to keep for each ordinary kind (e.g. 2)
    LongTermCap        \* Max long_term notes to keep (e.g. 3)

VARIABLES
    bank,              \* Sequence of notes: [kind |-> "...", priority |-> Nat]
    result,            \* Sequence of notes after compaction
    phase              \* "accumulating" | "compacting" | "done"

vars == <<bank, result, phase>>

\* Kinds and their priorities (matching OCaml code)
Kinds == {"goal", "decision", "progress", "long_term"}

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

AppendGoal ==
    /\ phase = "accumulating"
    /\ Len(bank) < TargetNotes * 2   \* Allow growth beyond target
    /\ bank' = Append(bank, [kind |-> "goal", priority |-> 72])
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
         \* Phase 1: kind-capped selection (respects per-kind caps)
         goals == SelectSeq(bank, LAMBDA n : n.kind = "goal")
         kept_goals == SubSeq(goals, 1, IF Len(goals) > SmallKindCap
                                          THEN SmallKindCap
                                          ELSE Len(goals))
         longtermNotes == SelectSeq(bank, LAMBDA n : n.kind = "long_term")
         kept_longterm == SubSeq(longtermNotes, 1, IF Len(longtermNotes) > LongTermCap
                                                   THEN LongTermCap
                                                   ELSE Len(longtermNotes))
         decisions == SelectSeq(bank, LAMBDA n : n.kind = "decision")
         kept_decisions == SubSeq(decisions, 1, IF Len(decisions) > SmallKindCap
                                                THEN SmallKindCap
                                                ELSE Len(decisions))
         progress == SelectSeq(bank, LAMBDA n : n.kind = "progress")
         remaining == TargetNotes - Len(kept_goals)
                                  - Len(kept_longterm)
                                  - Len(kept_decisions)
         kept_progress == SubSeq(progress, 1, IF Len(progress) > remaining
                                              THEN IF remaining > 0 THEN remaining ELSE 0
                                              ELSE Len(progress))
         capped == kept_goals \o kept_longterm \o kept_decisions \o kept_progress
         \* Phase 2: fallback fill (ignore kind caps to reach TargetNotes).
         \* Models keeper_memory_bank.ml:407-408:
         \*   if !selected_count < target_notes then
         \*     List.iter (fun row -> add_row ~ignore_kind_cap:true row) by_recency;
         deficit == TargetNotes - Len(capped)
         extra == IF deficit > 0
                  THEN SubSeq(bank, 1, IF Len(bank) > deficit THEN deficit ELSE Len(bank))
                  ELSE <<>>
       IN
         /\ result' = capped \o extra
         /\ phase' = "done"
         /\ UNCHANGED <<bank>>

\* ── Buggy compaction (priority-only, no kind caps) ────

BugPriorityOnlyCompact ==
    /\ phase = "compacting"
    /\ LET
         \* Just take the first TargetNotes entries (bank is appended
         \* in priority order: long_term(95) > decision(86) > goal(72) > progress(66))
         \* So highest-priority notes fill all slots, starving lower kinds.
         \*
         \* Sort by priority descending: long_term first, then decision,
         \* then goal, then progress. If there are more long_term notes
         \* than TargetNotes, goals get 0 slots.
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

\* Recent floor: compaction keeps at least min(bank_size, RecentFloor) notes.
\* OCaml: let recent_floor = max 16 (min 64 (target_notes / 5))
\* For our small model (TargetNotes=8), RecentFloor = max(16, min(64, 8/5)) = 16,
\* but bank never reaches 16 in the model, so the effective floor is Len(bank).
\* We express the general property: result is never smaller than
\* min(Len(bank), TargetNotes).  This catches a hypothetical bug where
\* compaction over-prunes below the available input.
RecentFloorRespected ==
    phase = "done" =>
        Len(result) >= IF Len(bank) < TargetNotes
                       THEN Len(bank)
                       ELSE TargetNotes

====
