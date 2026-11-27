---------------------- MODULE RetainedResultCarrier ----------------------
(***************************************************************************)
(* Why a Keeper holding many retained tool results is fenced, and the one  *)
(* change that keeps it out (RFC-retained-results-carrier-shrinks-to-an-   *)
(* address).                                                               *)
(*                                                                         *)
(* A vendor turn that does not complete keeps one receipt per tool call,   *)
(* and only an accepted Completed removes them. Every runtime attaches the *)
(* receipts after it has measured the request, so the request a provider   *)
(* sees is                                                                 *)
(*                                                                         *)
(*     fixed + history + carrier                                           *)
(*                                                                         *)
(* and the shrink walk halves history alone. Once fixed + carrier is over  *)
(* the window, every view is refused, then the floor, and the session is   *)
(* fenced: no step of the system makes the next request smaller.           *)
(*                                                                         *)
(* The clean model gives the carrier a second form whose size does not     *)
(* depend on the receipt count. A size refusal switches a run to it once,  *)
(* and only when it is strictly shorter; the run then asks again at the    *)
(* same capacity. Four ways to get this wrong are modelled, each as its    *)
(* own Next:                                                               *)
(*                                                                         *)
(*  - the walk before this RFC: a size refusal goes to history alone, and  *)
(*    the floor is refused while the address floor would fit;              *)
(*  - halving before the switch (the RFC's rejected alternative 2): no     *)
(*    lock, but a refused request for every halving the switch saves;      *)
(*  - a hook that switches back: a run may refuse forever;                 *)
(*  - a run that starts inline in place of a session a size refusal        *)
(*    closed: it sends again the receipts that turn carried and added.     *)
(*                                                                         *)
(* A size refusal that came before any tool effect reaches the hook. One   *)
(* that came after an effect ends the run: the run cannot send again, so   *)
(* the hook is not asked, and the session record is what tells the next    *)
(* run (RFC section 5.5). An untyped refusal never reaches the hook (RFC   *)
(* section 7) and is not modelled.                                         *)
(*                                                                         *)
(* Measured 2026-11-07 (masc#49634): 248 receipts, about 11.8 MB in the    *)
(* system prompt, about 9.8M tokens against a 1M window. The floor was     *)
(* refused and the Keeper stayed fenced until an operator moved the        *)
(* receipts out of the outbox.                                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
  Window,        \* the largest request the provider takes
  FixedSizes,    \* sizes of what no view removes (system prompt, tools,
                 \* goal); a run may start with any of them
  ReceiptBytes,  \* one receipt carried inline
  AddressBytes,  \* the carrier by address, whatever the receipt count
  MaxReceipts,   \* keeps TLC's environment finite; the system has no cap
  HistoryBytes,  \* the full history view
  TurnBytes      \* what a turn's own tool results can add to a request the
                 \* provider took

ASSUME
  /\ {Window, ReceiptBytes, AddressBytes, MaxReceipts, HistoryBytes, TurnBytes} \subseteq Nat
  /\ FixedSizes \subseteq Nat
  /\ FixedSizes # {}
  /\ ReceiptBytes > 0
  /\ AddressBytes > 0
  /\ MaxReceipts > 0

VARIABLES
  receipts,   \* receipts in the outbox
  fixed,      \* what no view removes, in the run in progress
  form,       \* the carrier form of the run in progress
  history,    \* history bytes of the view being sent
  phase,      \* "idle" between runs, "sending" in a run, "locked" once fenced
  closed      \* the session record says a size refusal closed the last run
              \* after an effect

vars == << receipts, fixed, form, history, phase, closed >>

Min(a, b) == IF a < b THEN a ELSE b

InlineBytes == receipts * ReceiptBytes

Carrier ==
  IF receipts = 0 THEN 0
  ELSE IF form = "inline" THEN InlineBytes ELSE AddressBytes

Request == fixed + history + Carrier

(* The smallest request a run can send: no history, the shorter form. *)
FloorFits ==
  fixed + (IF receipts = 0 THEN 0 ELSE Min(InlineBytes, AddressBytes)) <= Window

(* The address form is worth taking: there is something to carry and the
   address form is strictly shorter. *)
AddressIsShorter ==
  /\ receipts > 0
  /\ AddressBytes < InlineBytes

(* What makes the carrier hook answer Reprojected: the run is still inline
   and the address form is worth taking. *)
SwitchShortens ==
  /\ form = "inline"
  /\ AddressIsShorter

TypeOK ==
  /\ receipts \in 0..MaxReceipts
  /\ fixed \in FixedSizes
  /\ form \in {"inline", "address"}
  /\ history \in 0..HistoryBytes
  /\ phase \in {"idle", "sending", "locked"}
  /\ closed \in BOOLEAN

Init ==
  /\ receipts = 0
  /\ fixed \in FixedSizes
  /\ form = "inline"
  /\ history = 0
  /\ phase = "idle"
  /\ closed = FALSE

(* A vendor turn that did not complete kept the result of one more call. *)
Retain ==
  /\ phase = "idle"
  /\ receipts < MaxReceipts
  /\ receipts' = receipts + 1
  /\ UNCHANGED << fixed, form, history, phase, closed >>

(* A run starts on the full view. The form is not remembered between runs:
   a run starts inline, except the run that takes the place of a session a
   size refusal closed, which reads that from the session record and starts
   in the address form when that form is worth taking. Its claim replaces
   the record. *)
StartRun ==
  /\ phase = "idle"
  /\ phase' = "sending"
  /\ fixed' \in FixedSizes
  /\ form' = IF closed /\ AddressIsShorter THEN "address" ELSE "inline"
  /\ history' = HistoryBytes
  /\ closed' = FALSE
  /\ UNCHANGED receipts

(* The provider takes the request. A Completed acknowledges every receipt
   the run carried; any other end keeps them. *)
Accept ==
  /\ phase = "sending"
  /\ Request <= Window
  /\ phase' = "idle"
  /\ receipts' \in {0, receipts}
  /\ UNCHANGED << fixed, form, history, closed >>

(* A typed size refusal. The carrier hook switches the form and the run
   asks again at the same capacity. *)
RefuseAndSwitch ==
  /\ phase = "sending"
  /\ Request > Window
  /\ SwitchShortens
  /\ form' = "address"
  /\ UNCHANGED << receipts, fixed, history, phase, closed >>

(* The hook answered Unchanged, so the walk halves history. *)
RefuseAndShrink ==
  /\ phase = "sending"
  /\ Request > Window
  /\ ~SwitchShortens
  /\ history > 0
  /\ history' = history \div 2
  /\ UNCHANGED << receipts, fixed, form, phase, closed >>

(* The floor is refused and the hook has nothing left to change. *)
RefuseAtFloor ==
  /\ phase = "sending"
  /\ Request > Window
  /\ ~SwitchShortens
  /\ history = 0
  /\ phase' = "locked"
  /\ UNCHANGED << receipts, fixed, form, history, closed >>

(* The provider took the request, the turn's own tool results grew it past
   the window, and the size refusal came after an effect. The run cannot
   send again, so the hook is not asked: the run ends, the session record
   says why, and the turn may have kept the result of one more call. *)
RefuseAfterEffect ==
  /\ phase = "sending"
  /\ Request <= Window
  /\ Request + TurnBytes > Window
  /\ phase' = "idle"
  /\ closed' = TRUE
  /\ receipts' \in {receipts, Min(receipts + 1, MaxReceipts)}
  /\ UNCHANGED << fixed, form, history >>

Next ==
  \/ Retain
  \/ StartRun
  \/ Accept
  \/ RefuseAndSwitch
  \/ RefuseAndShrink
  \/ RefuseAtFloor
  \/ RefuseAfterEffect

SpecClean == Init /\ [][Next]_vars /\ WF_vars(Next)

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* A run is fenced only when the smallest request it can send is over the
   window. That case is the operator's, as the bounded-restart RFC says; the
   larger of FixedSizes makes the clean model reach it. *)
NoLockWhileFloorFits == (phase = "locked") => ~FloorFits

(* Receipts leave the outbox only when the provider took the request: the
   fix never drops results to make room. A size refusal after an effect also
   leaves [sending] for [idle]; it closes the session and takes no receipt. *)
ReceiptsLeaveOnlyOnAccept ==
  [][(receipts' < receipts)
       => (phase = "sending" /\ phase' = "idle" /\ ~closed')]_vars

(* The carrier hook comes before any halving: a run shrinks history only
   once switching has nothing left to shorten. *)
SwitchBeforeShrink ==
  (phase = "sending" /\ history < HistoryBytes) => ~SwitchShortens

(* Every run ends: the provider takes it, the floor fences it, or a size
   refusal after an effect closes it. *)
RunEnds == [](phase = "sending" => <>(phase # "sending"))

(* A run that takes the place of a session a size refusal closed does not
   start with the receipts inline while the address form is worth taking:
   that turn carried them, and may have added one. *)
SupersedingRunStartsShort ==
  [][(phase = "idle" /\ phase' = "sending" /\ closed)
       => (form' = "address" \/ ~AddressIsShorter)]_vars

(***************************************************************************)
(* The walk before this RFC: a size refusal goes to history alone.         *)
(***************************************************************************)
RefuseIgnoringCarrier ==
  /\ phase = "sending"
  /\ Request > Window
  /\ IF history > 0
       THEN /\ history' = history \div 2
            /\ UNCHANGED << receipts, fixed, form, phase, closed >>
       ELSE /\ phase' = "locked"
            /\ UNCHANGED << receipts, fixed, form, history, closed >>

NextBuggy == Next \/ RefuseIgnoringCarrier

SpecBuggy == Init /\ [][NextBuggy]_vars

(***************************************************************************)
(* Halving before the switch: the hook is asked only at the floor.         *)
(***************************************************************************)
ShrinkBeforeSwitch ==
  /\ phase = "sending"
  /\ Request > Window
  /\ history > 0
  /\ history' = history \div 2
  /\ UNCHANGED << receipts, fixed, form, phase, closed >>

NextShrinkFirst == Next \/ ShrinkBeforeSwitch

SpecShrinkFirst == Init /\ [][NextShrinkFirst]_vars

(***************************************************************************)
(* A hook that switches back to inline: nothing makes the run end.         *)
(***************************************************************************)
SwitchBack ==
  /\ phase = "sending"
  /\ Request > Window
  /\ form = "address"
  /\ form' = "inline"
  /\ UNCHANGED << receipts, fixed, history, phase, closed >>

NextSwitchBack == Next \/ SwitchBack

SpecSwitchBack == Init /\ [][NextSwitchBack]_vars /\ WF_vars(NextSwitchBack)

(***************************************************************************)
(* Every run starts inline, as before RFC section 5.5: the run that takes  *)
(* the place of a session a size refusal closed sends the receipts again.  *)
(***************************************************************************)
StartInlineAfterClose ==
  /\ phase = "idle"
  /\ phase' = "sending"
  /\ fixed' \in FixedSizes
  /\ form' = "inline"
  /\ history' = HistoryBytes
  /\ closed' = FALSE
  /\ UNCHANGED receipts

NextInlineAfterClose == Next \/ StartInlineAfterClose

SpecInlineAfterClose == Init /\ [][NextInlineAfterClose]_vars

=============================================================================
