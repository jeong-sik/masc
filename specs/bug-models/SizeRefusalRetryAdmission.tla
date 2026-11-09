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
(* No size is measured and no reported number is used to pick the next    *)
(* rung: the provider judges every request. Both refusal kinds step down  *)
(* the same way: a turn-text refusal (Codex input_too_large) counts only  *)
(* the turn field, a window refusal counts the whole request.             *)
(*                                                                         *)
(* A request is laid out in two fields. Layouts is every placement of the *)
(* parts, so TLC also visits placements no runtime uses today.            *)
(*                                                                         *)
(* Six ways to get this wrong are modelled, each as Next \/ BugAction:    *)
(*                                                                         *)
(*  - the refused rung is sent again;                                      *)
(*  - a refused Resume goes straight to the floor, skipping the fresh     *)
(*    Start;                                                               *)
(*  - a refusal of the full Start ends the run before the floor was asked;*)
(*  - a failed blob write ends the run with the refusal in hand instead of *)
(*    sending the floor with the carrier inline (#50170);                  *)
(*  - the floor's forms are written before the floor is chosen, and a run  *)
(*    that does not send the floor keeps them;                             *)
(*  - the fresh Start after a Resume refusal cuts history the Resume never *)
(*    sent, as the Claude Code lane does before this RFC.                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  TurnLimit,        \* the turn text the provider takes (Codex max_chars)
  WindowLimit,      \* the largest request, both fields counted
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
  phase        \* "sending" | "refused" | "accepted" | "ended"

vars == << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
           rung, forms, written, phase >>

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

(* The provider refuses a request whose turn text is over its bound, as
   Codex input_too_large does at turn/start, or whose whole is over the
   window. The walk does not ask which. *)
Refused(r, x) == Turn(r, x) > TurnLimit \/ Window(r, x) > WindowLimit

Lower(r) ==IF r = "resume" THEN "start" ELSE IF r = "start" THEN "floor" ELSE "none"

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

(* The provider answers. *)
Send ==
  /\ phase = "sending"
  /\ phase' = IF Refused(rung, forms) THEN "refused" ELSE "accepted"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

(* Step down one rung. The floor's forms are written as the floor is
   chosen, right before it is sent. *)
StepDown ==
  /\ phase = "refused"
  /\ Lower(rung) # "none"
  /\ rung' = Lower(rung)
  /\ forms' = FormsOf(rung')
  /\ written' = (written \/ rung' = "floor")
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk >>

(* No rung is left: the run ends with the refusal in hand. *)
End ==
  /\ phase = "refused"
  /\ Lower(rung) = "none"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

Next == Send \/ StepDown \/ End

SpecClean == Init /\ [][Next]_vars /\ WF_vars(Next)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* Every resend is the rung right below the refused request: no rung is
   sent again and none is skipped. *)
EveryResendStepsDown ==
  [][(phase = "refused" /\ phase' = "sending") => rung' = Lower(rung)]_vars

(* The fresh Start that answers a Resume refusal carries everything masc
   holds: the Resume sent none of masc's range, so nothing of it is cut. *)
FreshStartCarriesEverything ==
  [][(phase = "refused" /\ rung = "resume" /\ phase' = "sending" /\ rung' = "start")
       => forms' = Full]_vars

(* The floor's forms are written only for the floor the run sends. *)
WritesOnlyForTheFloor == written => rung = "floor"

(* A run ends without being accepted only when no rung is left. *)
EndsOnlyWhenNoRungIsLeft == (phase = "ended") => Lower(rung) = "none"

(* No run gives up while the provider would have accepted the floor. *)
NoPrematureEnd == (phase = "ended") => Refused("floor", Floor)

(* Every run is accepted or ends. *)
RunEnds == <>(phase \in {"accepted", "ended"})

(***************************************************************************)
(* The refused request is sent again.                                      *)
(***************************************************************************)
ResendTheRefusedRung ==
  /\ phase = "refused"
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

SpecResendRefused == Init /\ [][Next \/ ResendTheRefusedRung]_vars

(***************************************************************************)
(* A refused Resume goes straight to the floor; the fresh Start is skipped.*)
(***************************************************************************)
SkipTheFreshStart ==
  /\ phase = "refused"
  /\ rung = "resume"
  /\ rung' = "floor"
  /\ forms' = Floor
  /\ written' = TRUE
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk >>

SpecSkipFreshStart == Init /\ [][Next \/ SkipTheFreshStart]_vars

(***************************************************************************)
(* A refusal of the full Start ends the run; the floor is not asked.       *)
(***************************************************************************)
EndBeforeTheFloor ==
  /\ phase = "refused"
  /\ rung = "start"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

SpecSkipFloor == Init /\ [][Next \/ EndBeforeTheFloor]_vars

(***************************************************************************)
(* The blob write fails and the run ends with the refusal in hand (#50170).*)
(***************************************************************************)
EndOnWriteFailure ==
  /\ phase = "refused"
  /\ ~blobOk
  /\ Lower(rung) = "floor"
  /\ phase' = "ended"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  rung, forms, written >>

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
                  rung, forms, phase >>

SpecCommitFirst == Init /\ [][Next \/ WriteBeforeChoosing]_vars

(***************************************************************************)
(* The fresh Start after a Resume refusal carries half the range.          *)
(***************************************************************************)
CutOnTheSessionDrop ==
  /\ phase = "refused"
  /\ rung = "resume"
  /\ rung' = "start"
  /\ forms' = [Full EXCEPT !.history = HistoryFull \div 2]
  /\ phase' = "sending"
  /\ UNCHANGED << layout, fixedTurn, fixedSide, resumeTurn, vendor, blobOk,
                  written >>

SpecCutOnDrop == Init /\ [][Next \/ CutOnTheSessionDrop]_vars

=============================================================================
