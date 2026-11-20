--------------------------- MODULE LibrarianBottom ----------------------------
(*****************************************************************************)
(* The bottom of reading: one head item that fits no declared slot           *)
(* together with Memory, after the width memory has narrowed to that one     *)
(* item (RFC librarian-call-only-proposes section 7.4, the rows of section   *)
(* 9.3 that read a one-item verdict, E4 of section 12.2). LibrarianWidth     *)
(* stops above this item and LibrarianWriter keeps no size fact per slot     *)
(* (section 21.5); this model keeps them.                                    *)
(*                                                                           *)
(* A run is one head item. Two questions show it: with Memory, whose id      *)
(* changes with every Memory version, and alone, whose id does not. A        *)
(* called slot says what the constant table Verdict says to the question;    *)
(* up to MaxQuiet calls in a run come back silent instead (Busy, Lost).      *)
(* An ask walks the slots declared when it starts and calls none that has    *)
(* a size fact under the question's id; those are filled from the bottom.    *)
(* The writer learns the sized refusals first, whatever the result's         *)
(* basis. It reads the verdict only when that basis is the Memory now, and   *)
(* it folds over the slots declared now.                                     *)
(*                                                                           *)
(* Names, model = code (L7b)                                                 *)
(*   state "Asking", "Resting", "Refused_at_bottom"                          *)
(*                       Librarian_machine.state of the same names           *)
(*   state "Passed"      a commit passed the head item; what follows is the  *)
(*                       next unit, LibrarianWidth's                         *)
(*   passed              that commit: Read with shown With_memory or         *)
(*                       Item_alone, Skip (Item_exceeds_window)              *)
(*   asking.which        Librarian_bottom.which With_memory | Alone; the ask *)
(*                       is Read_range at Librarian_width.One_item, or       *)
(*                       Read_item_alone (Librarian_read_result.asked)       *)
(*   asking.basis        question.basis: the snapshot the tail named when    *)
(*                       the ask made the question                           *)
(*   asking.lane         asking.lane: the lane value the walk started on     *)
(*   asking.calls        the walked slots minus Librarian_bottom.known       *)
(*   QId(which, v)       Librarian_question_id.t of that question            *)
(*   declared, Kind      Librarian_memory_lane.t: http @ cli are the walked  *)
(*                       slot keys; Kind "unadmitted" is an id in its        *)
(*                       unadmitted list                                     *)
(*   Verdict values      Librarian_slot_outcome: Slot_answered, Refused      *)
(*                       (Sized Input_too_large | Output_over_reserve |      *)
(*                       Window_reached), Refused Unsized ("Unsized"),       *)
(*                       Silent _ ("Silent")                                 *)
(*   lastResult.slots    No_answer.slots; a slot filled from the bottom is   *)
(*                       Refused (Sized _) there, unmarked                   *)
(*   bottom, Learn, Fold Librarian_bottom.t, learn, fold; Fold's             *)
(*                       Unsized_left and Silent_left are one value, Not_all *)
(*   AskEnded            Ask_ended (Read_ended _) of the current ask         *)
(*   Write               a Write that commits a line: Memory changes         *)
(*   DeclarationChanged  Declaration_changed: one slot in or out             *)
(*   Pulse               Pulse, lane_held false                              *)
(*   Resume              Operator Resume                                     *)
(*                                                                           *)
(* Names with no code yet                                                    *)
(*   readAlone           L7c: the mark that the item was read alone          *)
(*   SkipItem            L7d: Operator (Skip_item _), Skip (Operator_skipped)*)
(*   lastResult, .asked, .judged, RowLane, E4                                *)
(*                       L9: the writer's last result, the row that carries  *)
(*                       it, and the E4 branch of the level function on it.  *)
(*                       E4 needs Unsized_left apart from Silent_left        *)
(*                                                                           *)
(* Properties                                                                *)
(*   DescendsOnlyOnInput     reading the item alone and skipping it for      *)
(*                           size start only when every slot declared now    *)
(*                           said Input_too_large to the question judged     *)
(*   BottomOnlyWhenAllSized  in Refused_at_bottom every slot declared now    *)
(*                           said a size fact to the question judged         *)
(*   NoCallOnFact            an ask calls no slot that has a size fact       *)
(*                           under its question's id                         *)
(*   UnsizedLaneStaysAbove   while a bare 400, silent or unadmitted slot     *)
(*                           is declared, the writer neither goes below      *)
(*                           the item nor stops at it. An answer or          *)
(*                           Skip_item passes it                             *)
(*   StaleVerdictNeverUsed   no descent and no stop on a verdict about an    *)
(*                           older Memory version                            *)
(*   E4Exact                 E4 is on exactly when the writer's last         *)
(*                           one-item verdict rested it on bare 400          *)
(*                           refusals, judged on the Memory and lane of now  *)
(*   E4Ends                  a declaration change or a Memory change turns   *)
(*                           E4 off                                          *)
(*                                                                           *)
(* Bugs: SpecBuggy adds the BugAction the constant Bug names                 *)
(*   remember_unsized   learn keeps a bare 400 and the bottom holds it as    *)
(*                      a size fact            -> BottomOnlyWhenAllSized     *)
(*   one_slot_enough    one Input_too_large is enough to descend             *)
(*                                             -> DescendsOnlyOnInput        *)
(*   stale_basis        the verdict is read whatever the result's basis      *)
(*                                             -> StaleVerdictNeverUsed      *)
(*   fold_over_result   the fold walks the result's slots, not the slots     *)
(*                      declared now           -> DescendsOnlyOnInput        *)
(*   recall_on_fact     a pulse's ask calls every declared slot              *)
(*                                             -> NoCallOnFact               *)
(* Rule E4Lane: "judged" compares the lane the writer folded over, and       *)
(* E4Exact holds. "asked" compares the lane the ask started on, as           *)
(* INTERFACES 1.3 writes read_seen.lane. A slot taken out during the ask     *)
(* then leaves the writer resting on Unsized_left with E4 off until the      *)
(* next pulse's ask ends, and E4Exact fails.                                 *)
(*                                                                           *)
(* Not modelled                                                              *)
(*   - The width memory and the asks wider than one item (LibrarianWidth).   *)
(*     Every ask here is a one-item question. A declaration change           *)
(*     empties the width memory; narrowing back down is not a step here.     *)
(*   - A lane digest is the set of slots declared: equal sets, equal         *)
(*     digests.                                                              *)
(*   - Make_room (L7c): the alone answer ends the run.                       *)
(*   - Stopped and boot, late answers, Turn_closed, lane_held (a pulse       *)
(*     while every slot is held starts nothing), the question side of the    *)
(*     lane (a change of it cancels the ask), a second item.                 *)
(*                                                                           *)
(* No rule here ends a state because time passed, and none holds an act      *)
(* back by a count. The Max* bounds say how often the environment acts;      *)
(* the writer reads only the declaration, the typed outcomes and the facts.  *)
(*****************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
  Slots,          \* the slots a run may declare
  Kind,           \* Kind[s] \in Kinds
  Verdict(_, _),  \* Verdict(s, q): what slot s says to question q when it is called
  Declared0,      \* the declaration the run starts with
  MaxVersion,     \* Memory versions 1..MaxVersion; a direct write moves to the next one
  MaxDecl,        \* bounds on the environment: declaration changes,
  MaxPulse,       \*   pulses that start an ask,
  MaxResume,      \*   Resume,
  MaxSkip,        \*   Skip_item,
  MaxQuiet,       \*   calls that come back silent from a slot that would have spoken
  E4Lane,         \* "judged": the row keeps the lane the writer judged under; "asked": the lane the ask started on
  Bug             \* read by SpecBuggy only

VARIABLES
  state,       \* "Asking" | "Resting" | "Refused_at_bottom" | "Passed"
  asking,      \* the ask in flight: [which, basis, lane, calls]
  memory,      \* the Memory version now (the snapshot)
  declared,    \* the slots declared now
  bottom,      \* the writer's size facts: << question id, slot, fact >>
  lastResult,  \* the last one-item result the writer handled
  passed,      \* how the head item was passed
  readAlone,   \* read_alone
  said,        \* ghost: << question id, slot, outcome >> of every call in the run
  env          \* how often the environment has acted

vars == << state, asking, memory, declared, bottom, lastResult, passed, readAlone, said, env >>

Kinds     == {"counting", "typed", "bare400", "silent", "unadmitted"}
SizeFacts == {"Input_too_large", "Output_over_reserve", "Window_reached"}
Outcomes  == {"Slot_answered", "Unsized", "Silent"} \cup SizeFacts
Open      == {"Asking", "Resting", "Refused_at_bottom"}

(* What a slot of each kind can say. Agent-Core counts a counting slot's input
   before sending; a typed slot's provider types its overflow; a bare 400 slot
   refuses with no size; a silent slot's client types no verdict; an unadmitted
   slot is declared and not walked (the registry did not admit it). *)
Speaks(k) == CASE k = "counting"   -> {"Slot_answered", "Input_too_large", "Output_over_reserve"}
               [] k = "typed"      -> {"Slot_answered"} \cup SizeFacts
               [] k = "bare400"    -> {"Slot_answered", "Unsized"}
               [] k = "silent"     -> {"Slot_answered", "Silent"}
               [] k = "unadmitted" -> {}

(* The question id. The alone question shows neither Memory nor the work in
   hand, so its id is the same at every Memory version. *)
QId(which, v) == IF which = "Alone" THEN << "Alone", 0 >> ELSE << "With_memory", v >>
Questions == { QId("With_memory", v) : v \in 1..MaxVersion } \cup { QId("Alone", 0) }

Walked(D) == { s \in D : Kind[s] # "unadmitted" }

ASSUME \A s \in Slots : Kind[s] \in Kinds
ASSUME \A s \in Slots, q \in Questions : Kind[s] # "unadmitted" => Verdict(s, q) \in Speaks(Kind[s])
ASSUME Declared0 \subseteq Slots /\ Walked(Declared0) # {}
ASSUME E4Lane \in {"judged", "asked"}

(* Constants for the cfgs. A: a counting, a typed and a bare 400 slot.
   Memory version 2 is larger: the typed slot then stops at its window. *)
SlotsA == {"a", "t", "u"}
KindA  == [s \in SlotsA |-> CASE s = "a" -> "counting" [] s = "t" -> "typed" [] s = "u" -> "bare400"]
VerdictA(s, q) ==
  CASE s = "a" -> "Input_too_large"
    [] s = "t" -> IF q[1] = "Alone" THEN "Slot_answered"
                  ELSE IF q[2] = 1 THEN "Input_too_large" ELSE "Window_reached"
    [] s = "u" -> "Unsized"
(* B: a counting, a typed, a silent and an unadmitted slot. *)
SlotsB     == {"a", "t", "s", "n"}
Declared0B == {"a", "t", "s"}
KindB  == [s \in SlotsB |-> CASE s = "a" -> "counting" [] s = "t" -> "typed"
                              [] s = "s" -> "silent"   [] s = "n" -> "unadmitted"]
VerdictB(s, q) ==
  CASE s = "a" -> IF q[1] = "With_memory" /\ q[2] = 2 THEN "Output_over_reserve" ELSE "Input_too_large"
    [] s = "t" -> IF q[1] = "Alone" THEN "Slot_answered"
                  ELSE IF q[2] = 1 THEN "Input_too_large" ELSE "Window_reached"
    [] s = "s" -> "Silent"
    [] s = "n" -> "Silent"

(* ---- the bottom: Librarian_bottom.known, learn, fold ---- *)
Known(B, q) == { x[2] : x \in { y \in B : y[1] = q } }
FactOf(B, q, s) == (CHOOSE x \in B : x[1] = q /\ x[2] = s)[3]

(* learn: the same id adds, another id replaces that kind's record. A result
   with no size fact leaves the record as it is. *)
Learn(B, q, E) ==
  IF E = {} THEN B
  ELSE LET kin  == { x \in B : x[1][1] = q[1] }
           base == IF \A x \in kin : x[1] = q THEN B ELSE B \ kin
       IN base \cup { << q, e[1], e[2] >> : e \in E }

(* fold reads one value per slot declared now. A slot the result does not
   hold is silent, and so is an unadmitted slot. A slot filled from the
   bottom holds a size fact. *)
SlotReads(slots, s) ==
  IF s \notin DOMAIN slots THEN "silent"
  ELSE IF slots[s].from = "bottom" \/ slots[s].out \in SizeFacts
    THEN IF slots[s].out = "Input_too_large" THEN "input" ELSE "sized"
  ELSE IF slots[s].out = "Unsized" THEN "unsized"
  ELSE "silent"
Fold(D, slots) ==
  LET seen == { SlotReads(slots, s) : s \in D } IN
  IF seen = {"input"} THEN "Input"
  ELSE IF seen \subseteq {"input", "sized"} THEN "All_not_input"
  ELSE IF "silent" \notin seen THEN "Unsized_left"
  ELSE "Silent_left"

(* ---- asks ---- *)
NoAsk == [which |-> "none", basis |-> 0, lane |-> {}, calls |-> {}]
(* The fiber reads the snapshot and gets the bottom when the ask starts, and
   calls no slot that has a fact under the question's id. *)
Ask(which, v, D, B) ==
  [which |-> which, basis |-> v, lane |-> D, calls |-> Walked(D) \ Known(B, QId(which, v))]
AskEveryone(which, v, D) == [which |-> which, basis |-> v, lane |-> D, calls |-> Walked(D)]

NoResult == [answered |-> FALSE, which |-> "none", basis |-> 0, asked |-> {}, judged |-> {},
             slots |-> [s \in {} |-> "none"], took |-> "none"]

Init ==
  /\ memory = 1 /\ declared = Declared0
  /\ state = "Asking" /\ asking = Ask("With_memory", 1, Declared0, {})
  /\ bottom = {} /\ said = {}
  /\ lastResult = NoResult /\ passed = "None" /\ readAlone = FALSE
  /\ env = [decl |-> 0, pulse |-> 0, resume |-> 0, skip |-> 0, quiet |-> 0]

(* Ask_ended of the current one-item ask. rule is "none" in Next; a BugAction
   passes the name of its bug. *)
AskEnded(rule) ==
  /\ state = "Asking"
  /\ \E quiet \in SUBSET asking.calls :
       /\ env.quiet + Cardinality(quiet) <= MaxQuiet
       /\ LET q      == QId(asking.which, asking.basis)
              out(s) == IF s \in quiet THEN "Silent" ELSE Verdict(s, q)
              spoke  == asking.calls \ quiet
          IN
          /\ said' = said \cup { << q, s, Verdict(s, q) >> : s \in spoke }
          /\ env' = [env EXCEPT !.quiet = @ + Cardinality(quiet)]
          /\ UNCHANGED << memory, declared >>
          /\ IF \E s \in spoke : Verdict(s, q) = "Slot_answered"
               THEN \* Answered: the commit passes the head item and empties the bottom
                    /\ state' = "Passed" /\ asking' = NoAsk
                    /\ passed' = IF asking.which = "Alone" THEN "Read_item_alone" ELSE "Read_with_memory"
                    /\ readAlone' = (asking.which = "Alone")
                    /\ bottom' = {}
                    /\ lastResult' = [NoResult EXCEPT !.answered = TRUE, !.which = asking.which,
                                                      !.basis = asking.basis]
               ELSE
                 LET slots == [s \in Walked(asking.lane) |->
                                 IF s \in asking.calls THEN [from |-> "call", out |-> out(s)]
                                 ELSE [from |-> "bottom", out |-> FactOf(bottom, q, s)]]
                     keeps == IF rule = "remember_unsized" THEN SizeFacts \cup {"Unsized"} ELSE SizeFacts
                     b1    == Learn(bottom, q, { << s, out(s) >> : s \in { x \in spoke : out(x) \in keeps } })
                     stale == asking.basis # memory /\ rule # "stale_basis"
                     \* no slot declared now has an outcome: slots-only changes during the ask moved them all
                     noOut == \A s \in declared : s \notin DOMAIN slots
                     over  == IF rule = "fold_over_result" THEN asking.lane ELSE declared
                     v     == IF rule = "one_slot_enough" /\ \E s \in DOMAIN slots : slots[s].out = "Input_too_large"
                                THEN "Input" ELSE Fold(over, slots)
                     took  == IF stale \/ noOut THEN "Next_ask"
                              ELSE IF v = "Input" THEN
                                     IF asking.which = "With_memory" THEN "Read_item_alone" ELSE "Item_exceeds_window"
                              ELSE IF v = "All_not_input" THEN "Refused_at_bottom"
                              ELSE IF v = "Unsized_left" THEN "Rest_unsized"
                              ELSE "Rest_silent"
                 IN /\ lastResult' = [answered |-> FALSE, which |-> asking.which, basis |-> asking.basis,
                                      asked |-> asking.lane, judged |-> declared, slots |-> slots, took |-> took]
                    /\ readAlone' = readAlone
                    /\ IF took = "Item_exceeds_window"
                         THEN \* Skip (Item_exceeds_window): the commit passes the head item
                              /\ state' = "Passed" /\ asking' = NoAsk /\ passed' = "Item_exceeds_window"
                              /\ bottom' = {}
                         ELSE /\ bottom' = b1 /\ passed' = passed
                              /\ CASE took = "Next_ask" ->
                                        state' = "Asking" /\ asking' = Ask("With_memory", memory, declared, b1)
                                   [] took = "Read_item_alone" ->     \* at once
                                        state' = "Asking" /\ asking' = Ask("Alone", memory, declared, b1)
                                   [] took = "Refused_at_bottom" ->
                                        state' = "Refused_at_bottom" /\ asking' = NoAsk
                                   [] took \in {"Rest_unsized", "Rest_silent"} ->
                                        state' = "Resting" /\ asking' = NoAsk

(* A pulse in Resting asks again; in Asking and Refused_at_bottom it does
   nothing, so it is no step there. *)
Pulse(rule) ==
  /\ state = "Resting" /\ env.pulse < MaxPulse
  /\ state' = "Asking"
  /\ asking' = IF rule = "recall_on_fact" THEN AskEveryone("With_memory", memory, declared)
               ELSE Ask("With_memory", memory, declared, bottom)
  /\ env' = [env EXCEPT !.pulse = @ + 1]
  /\ UNCHANGED << memory, declared, bottom, lastResult, passed, readAlone, said >>

(* A direct write that commits a line moves Memory to its next version. In
   Asking the ask goes on, in Resting the writer stays, in Refused_at_bottom
   it asks the question of the new Memory. *)
Write ==
  /\ state \in Open /\ memory < MaxVersion
  /\ memory' = memory + 1
  /\ IF state = "Refused_at_bottom"
       THEN state' = "Asking" /\ asking' = Ask("With_memory", memory + 1, declared, bottom)
       ELSE UNCHANGED << state, asking >>
  /\ UNCHANGED << declared, bottom, lastResult, passed, readAlone, said, env >>

(* One slot more or one fewer; a lane value walks at least one slot. A
   slots-only change lets the ask finish. The bottom stays: a changed slot
   is another key. *)
OneSlotMoved(D) ==
  { E \in { D \cup {s} : s \in Slots \ D } \cup { D \ {s} : s \in D } : Walked(E) # {} }
DeclarationChanged ==
  /\ state \in Open /\ env.decl < MaxDecl
  /\ \E D \in OneSlotMoved(declared) :
       /\ declared' = D
       /\ IF state = "Asking"
            THEN UNCHANGED << state, asking >>
            ELSE state' = "Asking" /\ asking' = Ask("With_memory", memory, D, bottom)
  /\ env' = [env EXCEPT !.decl = @ + 1]
  /\ UNCHANGED << memory, bottom, lastResult, passed, readAlone, said >>

(* Resume empties the bottom and asks again. In Asking it is refused and
   changes nothing. *)
Resume ==
  /\ state \in {"Resting", "Refused_at_bottom"} /\ env.resume < MaxResume
  /\ state' = "Asking" /\ asking' = Ask("With_memory", memory, declared, {})
  /\ bottom' = {}
  /\ env' = [env EXCEPT !.resume = @ + 1]
  /\ UNCHANGED << memory, declared, lastResult, passed, readAlone, said >>

(* Skip_item cancels the ask, commits Skip (Operator_skipped) and empties the
   bottom and the last result. *)
SkipItem ==
  /\ state \in Open /\ env.skip < MaxSkip
  /\ state' = "Passed" /\ asking' = NoAsk /\ passed' = "Operator_skipped"
  /\ bottom' = {} /\ lastResult' = NoResult
  /\ env' = [env EXCEPT !.skip = @ + 1]
  /\ UNCHANGED << memory, declared, readAlone, said >>

Next ==
  \/ AskEnded("none") \/ Pulse("none") \/ Write \/ DeclarationChanged \/ Resume \/ SkipItem

BugAction ==
  \/ Bug \in {"remember_unsized", "one_slot_enough", "stale_basis", "fold_over_result"} /\ AskEnded(Bug)
  \/ Bug = "recall_on_fact" /\ Pulse(Bug)

NextBuggy == Next \/ BugAction

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
  /\ state \in Open \cup {"Passed"}
  /\ (state = "Asking") <=> (asking.which # "none")
  /\ (state = "Passed") <=> (passed # "None")
  /\ passed \in {"None", "Read_with_memory", "Read_item_alone", "Item_exceeds_window", "Operator_skipped"}
  /\ memory \in 1..MaxVersion
  /\ declared \subseteq Slots /\ Walked(declared) # {}
  /\ bottom \subseteq Questions \X Slots \X SizeFacts
  /\ said \subseteq Questions \X Slots \X Outcomes
  /\ readAlone \in BOOLEAN

SaidTo(q, s) == { x[3] : x \in { y \in said : y[1] = q /\ y[2] = s } }

(* Steps that handle a one-item result and go below the item or stop at it. *)
StartsAlone  == state = "Asking" /\ asking.which = "With_memory" /\ state' = "Asking" /\ asking'.which = "Alone"
SkipsForSize == passed = "None" /\ passed' = "Item_exceeds_window"
StopsAtItem  == state # "Refused_at_bottom" /\ state' = "Refused_at_bottom"
Descends     == StartsAlone \/ SkipsForSize
JudgedNext   == QId(lastResult'.which, lastResult'.basis)

DescendsOnlyOnInput ==
  [][ Descends => \A s \in declared' : << JudgedNext, s, "Input_too_large" >> \in said' ]_vars

BottomOnlyWhenAllSized ==
  state = "Refused_at_bottom" =>
    \A s \in declared : SaidTo(QId(lastResult.which, lastResult.basis), s) \cap SizeFacts # {}

NoCallOnFact ==
  state = "Asking" => asking.calls \cap Known(bottom, QId(asking.which, asking.basis)) = {}

UnsizedLaneStaysAbove ==
  [][ (Descends \/ StopsAtItem) => \A s \in declared' : Kind[s] \in {"counting", "typed"} ]_vars

StaleVerdictNeverUsed ==
  [][ (Descends \/ StopsAtItem) => lastResult'.basis = memory' ]_vars

(* E4 as the level function reads the row: the last one-item result, folded
   over the slots declared now, has only bare 400 refusals left; its basis is
   the Memory now and its lane is the lane now. *)
RowLane == IF E4Lane = "asked" THEN lastResult.asked ELSE lastResult.judged
E4 ==
  /\ state # "Passed"
  /\ lastResult.which # "none" /\ ~lastResult.answered
  /\ lastResult.basis = memory /\ RowLane = declared
  /\ Fold(declared, lastResult.slots) = "Unsized_left"
(* What the writer did with that result, kept as it decided. *)
RestsOnBare400 ==
  /\ state # "Passed"
  /\ lastResult.took = "Rest_unsized"
  /\ lastResult.basis = memory /\ lastResult.judged = declared

E4Exact == E4 <=> RestsOnBare400

E4Ends == [][ (E4 /\ (declared' # declared \/ memory' # memory)) => ~E4' ]_vars

(* Reachability, each used in a -reachable-buggy cfg that must violate it. *)
NeverItemAlone         == ~(state = "Asking" /\ asking.which = "Alone")
NeverSizeSkip          == passed # "Item_exceeds_window"
NeverRefusedAtBottom   == state # "Refused_at_bottom"
NeverE4                == ~E4
NeverOneItemSilentRest == ~(state = "Resting" /\ lastResult.took = "Rest_silent")
=============================================================================
