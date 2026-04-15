------------------------------ MODULE CheckpointTrim ------------------------------
(* TLA+ spec for checkpoint message trimming.

   Verifies trim_messages_preserving_pairs never creates orphan
   ToolResult blocks (ToolResult without preceding ToolUse).

   Bug Model pattern (feedback_tla-spec-audit-outcome-trichotomy):
     Clean cfg: both invariants pass → spec valid
     Buggy cfg: ToolResultPaired violated → invariant catches the bug
     Both must hold for the spec to be useful.
*)

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS MaxLen,     \* max initial message count (e.g. 6)
          MaxCount    \* trim target (e.g. 3)

VARIABLES msgs, result, pc

vars == <<msgs, result, pc>>

\* Message kinds
T == "Text"
U == "ToolUse"
R == "ToolResult"

\* ── Invariant: no orphan ToolResult ─────────

Paired(seq) ==
    \A i \in 1..Len(seq) :
        seq[i] = R => (i > 1 /\ seq[i-1] = U)

\* ── Build all valid message sequences ───────
\* Valid: R must follow U. Enumerate by appending one msg at a time.

RECURSIVE ValidSeqs(_)
ValidSeqs(n) ==
    IF n = 0 THEN {<<>>}
    ELSE
        LET prev == ValidSeqs(n - 1)
        IN  { Append(s, T) : s \in prev }
            \cup { Append(s, U) : s \in prev }
            \cup { Append(Append(s, U), R) : s \in prev }  \* U+R pair

AllValid == UNION { ValidSeqs(n) : n \in 0..MaxLen }
InputSeqs == { s \in AllValid : Len(s) >= 1 /\ Len(s) <= MaxLen /\ Paired(s) }

\* ── Init ────────────────────────────────────

Init ==
    /\ msgs \in InputSeqs
    /\ result = <<>>
    /\ pc = "trim"

\* ── Clean trim (pair-preserving) ────────────

CleanTrim ==
    /\ pc = "trim"
    /\ LET n == Len(msgs)
           drop == IF n <= MaxCount THEN 0 ELSE n - MaxCount
           eDrop == IF drop > 0 /\ drop < n /\ msgs[drop + 1] = R
                    THEN drop + 1
                    ELSE drop
       IN result' = SubSeq(msgs, eDrop + 1, n)
    /\ pc' = "done"
    /\ UNCHANGED msgs

\* ── Buggy trim (flat index) ─────────────────

BuggyTrim ==
    /\ pc = "trim"
    /\ LET n == Len(msgs)
           drop == IF n <= MaxCount THEN 0 ELSE n - MaxCount
       IN result' = SubSeq(msgs, drop + 1, n)
    /\ pc' = "done"
    /\ UNCHANGED msgs

\* ── Specs ───────────────────────────────────

NextClean == CleanTrim
NextBuggy == BuggyTrim

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety ──────────────────────────────────

NoOrphan == pc = "done" => Paired(result)
CapOk    == pc = "done" => Len(result) <= MaxCount

================================================================================
