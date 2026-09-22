---------------------- MODULE LibrarianContinuityWidth ----------------------
(***************************************************************************)
(* How much one Librarian continuity pass reads after an earlier pass was  *)
(* refused (RFC-librarian-lifecycle 4.3, masc#37793).                      *)
(*                                                                         *)
(* A pass offers the oldest part of the backlog. A provider either takes   *)
(* it, refuses it for a reason a smaller request would avoid, or refuses   *)
(* it for a reason no smaller request would avoid (quota, an expired       *)
(* credential, a failure that never reached a provider). The pass does not *)
(* retry in place: it records what to read next time and ends.             *)
(*                                                                         *)
(* Three ways to get this wrong are modelled, each as its own Next:        *)
(*                                                                         *)
(*  - the narrowed width is not carried to the next pass, so every pass    *)
(*    offers the whole backlog again. This is what the live keeper did on  *)
(*    2026-09-22: 12756 -> 6378 -> 3189, ninety-six times, committing      *)
(*    nothing.                                                             *)
(*  - the width is released by one commit rather than by reading the       *)
(*    backlog to its end, so the search starts over after every unit.      *)
(*  - a refusal no smaller request would avoid narrows anyway, so a quota  *)
(*    storm walks the width to one atom and it stays there, because only   *)
(*    an emptied backlog releases it.                                      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  Backlog,   \* atoms unread when the trace begins
  Capacity   \* the largest unit a provider takes

VARIABLES
  unread,      \* atoms still to read
  width,       \* 0 = no limit in force; otherwise the atoms one pass may read
  learned,     \* 0 = none; otherwise the narrowest width any pass has learned
  refusedAt,   \* the smallest unit a provider has refused; Backlog + 1 when none
  outcome      \* how the last pass ended

vars == << unread, width, learned, refusedAt, outcome >>

Min(a, b) == IF a < b THEN a ELSE b

(* What this pass offers. Without a width in force it offers the backlog. *)
Unit == IF width = 0 THEN unread ELSE Min(width, unread)

(* The next step down. A unit a provider refused is at least two atoms, so
   this never reaches zero. *)
Narrower(n) == IF n <= 1 THEN 1 ELSE n \div 2

TypeOK ==
  /\ unread \in 0..Backlog
  /\ width \in 0..Backlog
  /\ learned \in 0..Backlog
  /\ refusedAt \in 1..(Backlog + 1)
  /\ outcome \in {"start", "committed", "refused_size", "refused_other"}

Init ==
  /\ unread = Backlog
  /\ width = 0
  /\ learned = 0
  /\ refusedAt = Backlog + 1
  /\ outcome = "start"

(* A unit that fits is read and committed. The width is released only when
   the backlog has been read to its end. *)
Commit ==
  /\ unread > 0
  /\ Unit <= Capacity
  /\ unread' = unread - Unit
  /\ width' = IF unread - Unit = 0 THEN 0 ELSE width
  /\ learned' = IF unread - Unit = 0 THEN 0 ELSE learned
  /\ UNCHANGED refusedAt
  /\ outcome' = "committed"

(* A refusal a smaller request would avoid. The pass records the narrower
   width and ends; it does not retry here. *)
RefuseSize ==
  /\ unread > 0
  /\ Unit > Capacity
  /\ width' = Narrower(Unit)
  /\ learned' = Narrower(Unit)
  /\ refusedAt' = Min(refusedAt, Unit)
  /\ UNCHANGED unread
  /\ outcome' = "refused_size"

(* A refusal no smaller request would avoid. The width stands. *)
RefuseOther ==
  /\ unread > 0
  /\ UNCHANGED << unread, width, learned, refusedAt >>
  /\ outcome' = "refused_other"

Drained == unread = 0 /\ UNCHANGED vars

Next == Commit \/ RefuseSize \/ RefuseOther \/ Drained

(* Weak fairness on the two actions that make progress. RefuseOther stays
   enabled throughout and is deliberately not fair: a provider may refuse
   this way any number of times without the pass losing what it learned. *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Commit) /\ WF_vars(RefuseSize)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* The backlog is read to its end. *)
Emptied == <>(unread = 0)

(* A pass never offers a unit a provider has already refused. *)
NoRefusedUnitOffered == (unread > 0) => (Unit < refusedAt)

(* What one pass learned bounds every later pass, until the backlog empties. *)
LearnedWidthHolds == (unread > 0 /\ learned > 0) => (Unit <= learned)

(* A refusal no smaller request would avoid leaves the width where it was. *)
WidthHoldsOnOtherRefusal ==
  [][ (outcome' = "refused_other") => (width' = width) ]_vars

(***************************************************************************)
(* The narrowed width is not carried to the next pass.                     *)
(***************************************************************************)
RefuseSizeWithoutCarry ==
  /\ unread > 0
  /\ Unit > Capacity
  /\ refusedAt' = Min(refusedAt, Unit)
  /\ UNCHANGED << unread, width, learned >>
  /\ outcome' = "refused_size"

NextNoCarry == Commit \/ RefuseSizeWithoutCarry \/ RefuseOther \/ Drained

SpecNoCarry ==
  Init /\ [][NextNoCarry]_vars /\ WF_vars(Commit) /\ WF_vars(RefuseSizeWithoutCarry)

(***************************************************************************)
(* One commit releases the width.                                          *)
(***************************************************************************)
CommitReleasingTheWidth ==
  /\ unread > 0
  /\ Unit <= Capacity
  /\ unread' = unread - Unit
  /\ width' = 0
  /\ UNCHANGED << learned, refusedAt >>
  /\ outcome' = "committed"

NextReleaseOnCommit ==
  CommitReleasingTheWidth \/ RefuseSize \/ RefuseOther \/ Drained

SpecReleaseOnCommit ==
  Init
  /\ [][NextReleaseOnCommit]_vars
  /\ WF_vars(CommitReleasingTheWidth)
  /\ WF_vars(RefuseSize)

(***************************************************************************)
(* A refusal no smaller request would avoid narrows anyway.                *)
(***************************************************************************)
RefuseOtherNarrowing ==
  /\ unread > 0
  /\ width' = Narrower(Unit)
  /\ learned' = Narrower(Unit)
  /\ UNCHANGED << unread, refusedAt >>
  /\ outcome' = "refused_other"

NextNarrowOnOther == Commit \/ RefuseSize \/ RefuseOtherNarrowing \/ Drained

SpecNarrowOnOther ==
  Init /\ [][NextNarrowOnOther]_vars /\ WF_vars(Commit) /\ WF_vars(RefuseSize)

=============================================================================
