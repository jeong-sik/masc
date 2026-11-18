---------------------------- MODULE LibrarianWidth ----------------------------
(***************************************************************************)
(* Width memory of the Librarian writer, two levels: whole units, then     *)
(* items of the head unit (RFC section 7.6).                               *)
(*                                                                         *)
(* One step is one ask. The lane's verdict on the ask is                   *)
(*   answer   the offered range weighs at most Capacity; it is committed,  *)
(*   refused  the offered range weighs more than Capacity,                 *)
(*   silent   the lane said nothing (possible at any time).                *)
(*                                                                         *)
(* refused: push { size = n; left = n } on the level the ask was on,       *)
(*          unless the innermost entry of that level is exactly that. A    *)
(*          one-unit ask whose unit holds two or more items also pushes    *)
(*          the item count on the item level.                              *)
(* answer : subtract what was committed from every entry of the level,     *)
(*          drop an entry at 0, empty the item level when a unit ends.     *)
(* next   : half of the innermost range while nothing of it is committed,  *)
(*          else what is left of it; everything when no range is held.     *)
(*                                                                         *)
(* su, si are what the writer remembers. gu, gi are ghosts kept by the     *)
(* reference rule (push on a refusal and hold a range once, subtract on a  *)
(* commit, drop at 0), so a buggy writer cannot hide a refused range by    *)
(* forgetting it.                                                          *)
(*                                                                         *)
(* Not modelled: one item that fits no slot (the bottom, its own model),   *)
(* slots, Memory, and what empties the memory (boot, a changed             *)
(* declaration).                                                           *)
(***************************************************************************)
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
  Backlog,      \* unread when the trace begins: a sequence of units, each a sequence of item weights
  Shapes,       \* units that may arrive later
  MaxArrivals,  \* how many units may arrive
  Capacity,     \* the largest total weight the lane answers
  Bug,          \* "none" | "release_on_commit" | "no_carry" | "narrow_on_silence" | "skip_push_when_left_is_n"
  MaxStack      \* state constraint only; the literal rule grows the stack without bound

VARIABLES
  units,       \* unread units, head first
  su, si,      \* writer memory: refused unit ranges, refused item ranges (innermost first)
  gu, gi,      \* ghost: the same stacks kept by the reference rule
  w,           \* width of the next ask
  arrivals,
  last,        \* how the last step ended
  pos,         \* ghost: items committed so far
  refusedSet   \* ghost: << pos, items offered >> of every refused ask

vars == << units, su, si, gu, gi, w, arrivals, last, pos, refusedSet >>

\* Constant values for the cfgs (a cfg cannot spell a sequence of sequences).
BacklogA == << <<2, 1, 1>>, <<1>>, <<1, 1>>, <<1>> >>      \* a heavy head item, the operator RFC's example shape
ShapesA  == { <<1>>, <<1, 1, 1>> }
BacklogB == << <<1>>, <<1>>, <<1>>, <<1>>, <<1>>, <<1>>, <<1>>, <<1>> >>   \* eight one-item units
ShapesB  == { <<1>> }
BacklogC == << <<1, 1, 1, 1, 1>>, <<1, 1>> >>               \* one long unit: the item level
ShapesC  == { <<1, 1>> }

Min(a, b) == IF a < b THEN a ELSE b

RECURSIVE Sum(_)
Sum(s) == IF s = << >> THEN 0 ELSE Head(s) + Sum(Tail(s))
RECURSIVE Weight(_)
Weight(us) == IF us = << >> THEN 0 ELSE Sum(Head(us)) + Weight(Tail(us))
RECURSIVE ItemCount(_)
ItemCount(us) == IF us = << >> THEN 0 ELSE Len(Head(us)) + ItemCount(Tail(us))

Take(s, n) == SubSeq(s, 1, Min(n, Len(s)))
Drop(s, n) == SubSeq(s, Min(n, Len(s)) + 1, Len(s))

All  == [k |-> "all", n |-> 0]
U(n) == [k |-> "units", n |-> n]
I(n) == [k |-> "items", n |-> n]

Entry(n) == [size |-> n, left |-> n]
Positive(e) == e.left > 0
Sub(stack, k) ==
  SelectSeq([i \in 1..Len(stack) |-> [stack[i] EXCEPT !.left = @ - k]], Positive)

(* ---- what the ask at width w offers; defined while units is not empty ---- *)
OfferUnits == CASE w.k = "all"   -> Len(units)
                [] w.k = "units" -> Min(w.n, Len(units))
                [] w.k = "items" -> 1
HeadItems  == IF w.k = "items" THEN Min(w.n, Len(units[1])) ELSE Len(units[1])
Offered    == IF w.k = "items" THEN << Take(units[1], w.n) >> ELSE Take(units, OfferUnits)
OfferedItems  == ItemCount(Offered)
OfferedWeight == Weight(Offered)
PartialHead   == w.k = "items" /\ HeadItems < Len(units[1])
FullUnits     == IF PartialHead THEN 0 ELSE OfferUnits

(* ---- next ---- *)
EntryWidth(e) ==
  IF e.left = e.size /\ e.size >= 2 THEN e.size \div 2 ELSE e.left
NextW(u, i) ==
  IF i # << >> THEN I(EntryWidth(i[1]))
  ELSE IF u # << >> THEN U(EntryWidth(u[1]))
  ELSE All

TypeOK ==
  /\ arrivals \in 0..MaxArrivals
  /\ w.k \in {"all", "units", "items"}
  /\ w.n \in Nat
  /\ last \in {"start", "answer", "refused", "silent", "arrive"}
  /\ pos \in Nat

Init ==
  /\ units = Backlog
  /\ su = << >> /\ si = << >> /\ gu = << >> /\ gi = << >>
  /\ w = All
  /\ arrivals = 0
  /\ last = "start"
  /\ pos = 0
  /\ refusedSet = {}

(* answer *)
AfterCommitU(stack) == IF PartialHead THEN stack ELSE Sub(stack, FullUnits)
AfterCommitI(stack) == IF PartialHead THEN Sub(stack, HeadItems) ELSE << >>

Answer ==
  /\ units # << >>
  /\ OfferedWeight <= Capacity
  /\ units' = IF PartialHead THEN << Drop(units[1], HeadItems) >> \o Tail(units)
              ELSE Drop(units, OfferUnits)
  /\ gu' = AfterCommitU(gu)
  /\ gi' = AfterCommitI(gi)
  /\ su' = IF Bug = "release_on_commit" THEN << >> ELSE AfterCommitU(su)
  /\ si' = IF Bug = "release_on_commit" THEN << >> ELSE AfterCommitI(si)
  /\ w' = NextW(su', si')
  /\ pos' = pos + OfferedItems
  /\ last' = "answer"
  /\ UNCHANGED << arrivals, refusedSet >>

(* refused. One item is the bottom; it is not reached here because every
   item weighs at most Capacity. *)
Same(stack, n) ==
  /\ stack # << >>
  /\ IF Bug = "skip_push_when_left_is_n" THEN stack[1].left = n ELSE stack[1] = Entry(n)
Push(stack, n) == IF Same(stack, n) THEN stack ELSE << Entry(n) >> \o stack
PushUnits(stack) == IF w.k = "items" THEN stack ELSE Push(stack, OfferUnits)
PushItems(stack) ==
  IF w.k = "items" THEN Push(stack, HeadItems)
  ELSE IF OfferUnits = 1 /\ HeadItems >= 2 THEN Push(stack, HeadItems)
  ELSE stack
(* The reference: push without a test, then hold a range once. *)
RefPushUnits(stack) == IF w.k = "items" THEN stack ELSE << Entry(OfferUnits) >> \o stack
RefPushItems(stack) == IF OfferUnits >= 2 THEN stack ELSE << Entry(HeadItems) >> \o stack
Narrower ==
  IF OfferUnits >= 2 THEN U(OfferUnits \div 2) ELSE I(HeadItems \div 2)

(* The ghost holds a range once: the same range refused again is the same
   range. With Bug = "none" MemoryIsReference shows the writer's test is
   that one. *)
Once(old, new) ==
  IF old # << >> /\ Len(new) = Len(old) + 1 /\ new[1] = old[1] THEN old ELSE new

Refuse ==
  /\ units # << >>
  /\ OfferedWeight > Capacity
  /\ OfferUnits >= 2 \/ HeadItems >= 2
  /\ gu' = Once(gu, RefPushUnits(gu))
  /\ gi' = Once(gi, RefPushItems(gi))
  /\ IF Bug = "no_carry"
       THEN /\ UNCHANGED << su, si >>
            /\ w' = NextW(su, si)
       ELSE /\ su' = PushUnits(su)
            /\ si' = PushItems(si)
            /\ w' = Narrower          \* the next ask starts at once at the narrower width
  /\ refusedSet' = refusedSet \cup { << pos, OfferedItems >> }
  /\ last' = "refused"
  /\ UNCHANGED << units, arrivals, pos >>

(* The lane said nothing. The writer rests; the next pulse asks at the
   width the memory gives. *)
Silent ==
  /\ units # << >>
  /\ IF Bug = "narrow_on_silence" /\ (OfferUnits >= 2 \/ HeadItems >= 2)
       THEN /\ su' = PushUnits(su)
            /\ si' = PushItems(si)
            /\ w' = Narrower
       ELSE /\ UNCHANGED << su, si >>
            /\ w' = NextW(su, si)
  /\ last' = "silent"
  /\ UNCHANGED << units, gu, gi, arrivals, pos, refusedSet >>

Arrive ==
  /\ arrivals < MaxArrivals
  /\ \E s \in Shapes : units' = Append(units, s)
  /\ arrivals' = arrivals + 1
  /\ last' = "arrive"
  /\ UNCHANGED << su, si, gu, gi, w, pos, refusedSet >>

Next == Answer \/ Refuse \/ Silent \/ Arrive

(* Fair on the two verdicts that speak about the question. Silent is not
   fair: the lane may say nothing any number of times. *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Answer) /\ WF_vars(Refuse)

StackBound ==
  /\ Len(su) <= MaxStack /\ Len(si) <= MaxStack
  /\ Len(gu) <= MaxStack /\ Len(gi) <= MaxStack

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* (a) first half: an ask never passes the end of a refused range in force. *)
NeverPassesRefusedEnd ==
  units # << >> =>
    /\ \A i \in 1..Len(gu) : OfferUnits <= gu[i].left
    /\ gi # << >> => /\ OfferUnits = 1
                     /\ \A i \in 1..Len(gi) : HeadItems <= gi[i].left

(* (a) second half: an ask never offers a whole refused range again.
   A one-unit entry is pushed together with an item entry for the same
   bytes; while item entries exist, that unit is judged by them (its count
   of whole units cannot tell "the unit again" from "the rest of the unit"). *)
NeverWholeRefusedRangeAgain ==
  units # << >> =>
    /\ \A i \in 1..Len(gu) :
         (gu[i].left = gu[i].size /\ (gu[i].size >= 2 \/ gi = << >>)) => FullUnits < gu[i].size
    /\ \A i \in 1..Len(gi) : gi[i].left = gi[i].size => HeadItems < gi[i].size

(* The same, stated on bytes: a range that was refused from this position
   is never the next ask. *)
NotRefusedBefore == units # << >> => << pos, OfferedItems >> \notin refusedSet

(* (b) one refusal never narrows by more than half (rounded down), and
   never to nothing. *)
HalfStep ==
  [][ last' = "refused" =>
        IF OfferUnits >= 2
          THEN w'.k = "units" /\ w'.n >= 1 /\ 2 * w'.n + 1 >= OfferUnits
          ELSE w'.k = "items" /\ w'.n >= 1 /\ 2 * w'.n + 1 >= HeadItems ]_vars

(* (c) a silent verdict changes neither the stack nor the next width. *)
SilenceChangesNothing ==
  [][ last' = "silent" => su' = su /\ si' = si /\ w' = w ]_vars

(* (d) with no refused range in force the ask offers everything unread. *)
NoEntryOffersAll == (gu = << >> /\ gi = << >>) => w = All

(* (e) the backlog drains, also when units keep arriving a bounded number of times. *)
Drains == <>[](units = << >>)

(* With no bug the writer's memory is the reference memory. *)
MemoryIsReference == Bug = "none" => su = gu /\ si = gi

(* Reachability, each used negated in a -reachable-buggy cfg. *)
NeverItemLevel == si = << >>
NeverTwoRangesHeld == Len(su) < 2
=============================================================================
