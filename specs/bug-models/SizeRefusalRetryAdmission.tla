-------------------- MODULE SizeRefusalRetryAdmission --------------------
(***************************************************************************)
(* What a run sends after a typed size refusal that came before any effect *)
(* (RFC-size-refusal-starts-fresh-then-cuts-to-the-floor).                 *)
(*                                                                         *)
(* A run sends from three fixed rungs and only ever steps down:            *)
(*                                                                         *)
(*  - resume: the vendor session plus what a Resume adds to it. masc can   *)
(*    neither see nor cut the session;                                     *)
(*  - start: a fresh Start carrying everything masc holds, every part in   *)
(*    its full form;                                                       *)
(*  - floor: a fresh Start with every part in its smallest form. The       *)
(*    carrier's address form needs a blob written first; when that write  *)
(*    fails, the carrier stays inline and the floor is sent anyway.        *)
(*                                                                         *)
(* No size is measured to pick the next rung: the provider judges every    *)
(* request. A turn-text refusal (Codex input_too_large) also reports its   *)
(* bound, max_chars. From then on masc counts each rung's turn text before *)
(* sending it and skips a rung over the bound. masc's count is taken to    *)
(* equal the provider's here; the RFC cross-checks it against actual_chars.*)
(*                                                                         *)
(* A request is laid out in two fields. The turn field holds the turn text *)
(* a turn-text refusal counts; a window refusal counts both fields.        *)
(* Layouts is every placement of the parts, so TLC also visits placements  *)
(* no runtime uses today.                                                  *)
(*                                                                         *)
(* Six ways to get this wrong are modelled, each as Next \/ BugAction:     *)
(*                                                                         *)
(*  - the refused rung is sent again;                                      *)
(*  - after a turn-text refusal, a rung over the reported bound is sent,   *)
(*    as the Codex input_too_large ladder does before this RFC;            *)
(*  - a window refusal of the full Start ends the run before the floor     *)
(*    was asked;                                                           *)
(*  - a failed blob write ends the run with the refusal in hand instead of *)
(*    sending the floor with the carrier inline (#50170);                  *)
(*  - the floor's forms are written before the floor is chosen, and a run  *)
(*    that does not send the floor keeps them;                             *)
(*  - the fresh Start after a Resume refusal cuts history the Resume never *)
(*    sent, as the Claude Code lane does before this RFC.                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  TurnLimit,        \* the bound a turn-text refusal reports (max_chars)
  WindowLimit,      \* the largest request, both fields counted; never reported
  FixedTurnSizes,   \* what no form change removes from the turn field (goal)
  FixedSideSizes,   \* what no form change removes from the other field
  ResumeTurnSizes,  \* the turn text a Resume sends
  VendorSizes,      \* what the vendor session holds, unseen by masc
  CarrierInline,    \* the carrier with every receipt inline
  CarrierAddress,   \* the carrier by address
  MemoryFull,       \* memory delivered in full
  MemoryDeferred,   \* memory deferred to its status line
  HistoryFull,      \* the whole carried range
  HistoryFloor      \* the range the floor keeps

Fields    == {"turn", "side"}
Kinds     == {"window", "turn_text"}
Rungs     == {"resume", "start", "floor"}
Layouts   == [carrier : Fields, memory : Fields, history : Fields]
Histories == {HistoryFloor, HistoryFull \div 2, HistoryFull}
Forms     == [carrier : {"inline", "address"},
              memory : {"full", "deferred"},
              history : Histories]

ASSUME
  /\ {TurnLimit, WindowLimit, CarrierInline, CarrierAddress, MemoryFull,
      MemoryDeferred, HistoryFull, HistoryFloor} \subseteq Nat
  /\ TurnLimit > 0
  /\ FixedTurnSizes \subseteq Nat /\ FixedTurnSizes # {}
  /\ FixedSideSizes \subseteq Nat /\ FixedSideSizes # {}
  /\ ResumeTurnSizes \subseteq Nat \ {0} /\ ResumeTurnSizes # {}
  /\ VendorSizes \subseteq Nat /\ VendorSizes # {}

VARIABLES
  layout,      \* where the carrier, memory and history travel in this run
  fixedTurn,   \* what no form change removes from the turn field
  fixedSide,   \* what no form change removes from the other field
  resumeTurn,  \* the turn text the run's Resume sends; 0 for a run that starts fresh
  vendor,      \* what the vendor session holds; 0 for a run that starts fresh
  blobOk,      \* whether the carrier's blob write succeeds in this run
  rung,        \* the rung of the request in hand
  forms,       \* the forms masc's parts take in that request
  written,     \* whether the floor's forms have been written
  phase,       \* "sending" | "refused" | "accepted" | "ended"
  kind,        \* the kind of the last refusal; "none" before the first
  bound        \* the turn-text bound a refusal reported; 0 while none has

vars == << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
           rung, forms, written, phase, kind, bound >>

Full == [carrier |-> "inline", memory |-> "full", history |-> HistoryFull]

(* Every part in its smallest form. The address form needs its blob. *)
Floor == [carrier |-> IF blobOk THEN "address" ELSE "inline",
          memory  |-> "deferred",
          history |-> HistoryFloor]

FormsOf(r) == IF r = "floor" THEN Floor ELSE Full

(* Size of one field for forms x. *)
FieldSize(f, x) ==
    (IF f = "turn" THEN fixedTurn ELSE fixedSide)
  + (IF layout.carrier = f
       THEN (IF x.carrier = "inline" THEN CarrierInline ELSE CarrierAddress)
       ELSE 0)
  + (IF layout.memory = f
       THEN (IF x.memory = "full" THEN MemoryFull ELSE MemoryDeferred)
       ELSE 0)
  + (IF layout.history = f THEN x.history ELSE 0)

(* What each refusal kind counts, for rung r with forms x. A Resume sends
   none of masc's range: its turn text and the vendor session are all. *)
Turn(r, x)   == IF r = "resume" THEN resumeTurn ELSE FieldSize("turn", x)
Window(r, x) == IF r = "resume"
                  THEN resumeTurn + vendor
                  ELSE FieldSize("turn", x) + FieldSize("side", x)

Order(r) == IF r = "resume" THEN 0 ELSE IF r = "start" THEN 1 ELSE 2
Lower(r) == IF r = "resume" THEN "start" ELSE IF r = "start" THEN "floor" ELSE "none"

(* A rung may be sent unless a reported bound is known to exclude it. *)
Fits(r) == bound = 0 \/ Turn(r, FormsOf(r)) <= bound

(* The next rung down that may be sent; "none" when no rung is left. *)
NextRung(r) ==
  IF r = "resume"
    THEN IF Fits("start") THEN "start"
         ELSE IF Fits("floor") THEN "floor" ELSE "none"
  ELSE IF r = "start"
    THEN IF Fits("floor") THEN "floor" ELSE "none"
  ELSE "none"

(* What the provider accepts, as Send answers. *)
Acceptable(x) ==
  /\ FieldSize("turn", x) <= TurnLimit
  /\ FieldSize("turn", x) + FieldSize("side", x) <= WindowLimit

TypeOK ==
  /\ layout \in Layouts
  /\ fixedTurn \in FixedTurnSizes
  /\ fixedSide \in FixedSideSizes
  /\ resumeTurn \in ResumeTurnSizes \cup {0}
  /\ vendor \in VendorSizes \cup {0}
  /\ blobOk \in BOOLEAN
  /\ rung \in Rungs
  /\ forms \in Forms
  /\ written \in BOOLEAN
  /\ phase \in {"sending", "refused", "accepted", "ended"}
  /\ kind \in Kinds \cup {"none"}
  /\ bound \in {0, TurnLimit}

Init ==
  /\ layout \in Layouts
  /\ fixedTurn \in FixedTurnSizes
  /\ fixedSide \in FixedSideSizes
  /\ blobOk \in BOOLEAN
  /\ \/ /\ rung = "resume"
        /\ resumeTurn \in ResumeTurnSizes
        /\ vendor \in VendorSizes
     \/ /\ rung = "start"
        /\ resumeTurn = 0
        /\ vendor = 0
  /\ forms = Full
  /\ written = FALSE
  /\ phase = "sending"
  /\ kind = "none"
  /\ bound = 0

(* The provider answers. The turn text is checked before the model reads
   anything, as Codex does at turn/start; then the whole window. *)
Send ==
  /\ phase = "sending"
  /\ IF Turn(rung, forms) > TurnLimit
       THEN /\ phase' = "refused"
            /\ kind' = "turn_text"
            /\ bound' = TurnLimit
       ELSE IF Window(rung, forms) > WindowLimit
         THEN /\ phase' = "refused"
              /\ kind' = "window"
              /\ UNCHANGED bound
         ELSE /\ phase' = "accepted"
              /\ UNCHANGED << kind, bound >>
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

(* Step down one rung, or two when a known bound excludes the first. The
   floor's forms are written as the floor is chosen, right before it is
   sent. *)
StepDown ==
  /\ phase = "refused"
  /\ NextRung(rung) # "none"
  /\ rung' = NextRung(rung)
  /\ forms' = FormsOf(rung')
  /\ written' = (written \/ rung' = "floor")
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  kind, bound >>

(* No rung is left: the run ends with the refusal in hand. *)
End ==
  /\ phase = "refused"
  /\ NextRung(rung) = "none"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written, kind, bound >>

Next == Send \/ StepDown \/ End

SpecClean == Init /\ [][Next]_vars /\ WF_vars(Next)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* Every resend is a lower rung than the refused request. *)
EveryResendStepsDown ==
  [][(phase = "refused" /\ phase' = "sending") => Order(rung') > Order(rung)]_vars

(* Once a refusal reported its bound, no resend is over it by masc's count. *)
NoResendOverTheBound ==
  [][(phase = "refused" /\ phase' = "sending" /\ bound > 0)
       => Turn(rung', forms') <= bound]_vars

(* The fresh Start that answers a Resume refusal carries everything masc
   holds: the Resume sent none of masc's range, so nothing of it is cut. *)
FreshStartCarriesEverything ==
  [][(phase = "refused" /\ rung = "resume" /\ phase' = "sending" /\ rung' = "start")
       => forms' = Full]_vars

(* The floor's forms are written only for the floor the run sends. *)
WritesOnlyForTheFloor == written => rung = "floor"

(* A run ends without being accepted only when no rung is left. *)
EndsOnlyWhenNoRungIsLeft == (phase = "ended") => NextRung(rung) = "none"

(* No run gives up while the provider would have accepted the floor. *)
NoPrematureEnd == (phase = "ended") => ~Acceptable(Floor)

(* Every run is accepted or ends. *)
RunEnds == <>(phase \in {"accepted", "ended"})

(***************************************************************************)
(* The refused request is sent again.                                      *)
(***************************************************************************)
ResendTheRefusedRung ==
  /\ phase = "refused"
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written, kind, bound >>

SpecResendRefused == Init /\ [][Next \/ ResendTheRefusedRung]_vars

(***************************************************************************)
(* The next rung is sent though masc counted it over the reported bound.   *)
(***************************************************************************)
SendOverTheBound ==
  /\ phase = "refused"
  /\ bound > 0
  /\ Lower(rung) # "none"
  /\ ~Fits(Lower(rung))
  /\ rung' = Lower(rung)
  /\ forms' = FormsOf(rung')
  /\ written' = (written \/ rung' = "floor")
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  kind, bound >>

SpecOverBound == Init /\ [][Next \/ SendOverTheBound]_vars

(***************************************************************************)
(* A window refusal of the full Start ends the run; the floor is not asked.*)
(***************************************************************************)
EndBeforeTheFloor ==
  /\ phase = "refused"
  /\ kind = "window"
  /\ rung = "start"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written, kind, bound >>

SpecSkipFloor == Init /\ [][Next \/ EndBeforeTheFloor]_vars

(***************************************************************************)
(* The blob write fails and the run ends with the refusal in hand (#50170).*)
(***************************************************************************)
EndOnWriteFailure ==
  /\ phase = "refused"
  /\ ~blobOk
  /\ NextRung(rung) = "floor"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written, kind, bound >>

SpecWriteFailure == Init /\ [][Next \/ EndOnWriteFailure]_vars

(***************************************************************************)
(* The floor's forms are written on a refusal before the floor is chosen.  *)
(***************************************************************************)
WriteBeforeChoosing ==
  /\ phase = "refused"
  /\ rung # "floor"
  /\ ~written
  /\ written' = TRUE
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, phase, kind, bound >>

SpecCommitFirst == Init /\ [][Next \/ WriteBeforeChoosing]_vars

(***************************************************************************)
(* The fresh Start after a Resume refusal carries half the range.          *)
(***************************************************************************)
CutOnTheSessionDrop ==
  /\ phase = "refused"
  /\ rung = "resume"
  /\ Fits("start")
  /\ rung' = "start"
  /\ forms' = [Full EXCEPT !.history = HistoryFull \div 2]
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  written, kind, bound >>

SpecCutOnDrop == Init /\ [][Next \/ CutOnTheSessionDrop]_vars

=============================================================================
