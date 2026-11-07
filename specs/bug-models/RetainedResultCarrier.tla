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
(* same capacity. The buggy model is the walk before this RFC: a size      *)
(* refusal goes to history alone.                                          *)
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
  HistoryBytes   \* the full history view

ASSUME
  /\ {Window, ReceiptBytes, AddressBytes, MaxReceipts, HistoryBytes} \subseteq Nat
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
  phase       \* "idle" between runs, "sending" in a run, "locked" once fenced

vars == << receipts, fixed, form, history, phase >>

Min(a, b) == IF a < b THEN a ELSE b

InlineBytes == receipts * ReceiptBytes

Carrier ==
  IF receipts = 0 THEN 0
  ELSE IF form = "inline" THEN InlineBytes ELSE AddressBytes

Request == fixed + history + Carrier

(* The smallest request a run can send: no history, the shorter form. *)
FloorFits ==
  fixed + (IF receipts = 0 THEN 0 ELSE Min(InlineBytes, AddressBytes)) <= Window

(* What makes the carrier hook answer Reprojected: the run is still inline,
   there is something to carry, and the address form is strictly shorter. *)
SwitchShortens ==
  /\ form = "inline"
  /\ receipts > 0
  /\ AddressBytes < InlineBytes

TypeOK ==
  /\ receipts \in 0..MaxReceipts
  /\ fixed \in FixedSizes
  /\ form \in {"inline", "address"}
  /\ history \in 0..HistoryBytes
  /\ phase \in {"idle", "sending", "locked"}

Init ==
  /\ receipts = 0
  /\ fixed \in FixedSizes
  /\ form = "inline"
  /\ history = 0
  /\ phase = "idle"

(* A vendor turn that did not complete kept the result of one more call. *)
Retain ==
  /\ phase = "idle"
  /\ receipts < MaxReceipts
  /\ receipts' = receipts + 1
  /\ UNCHANGED << fixed, form, history, phase >>

(* Every run starts on the full view with the carrier inline: the form is
   not remembered between runs. *)
StartRun ==
  /\ phase = "idle"
  /\ phase' = "sending"
  /\ fixed' \in FixedSizes
  /\ form' = "inline"
  /\ history' = HistoryBytes
  /\ UNCHANGED receipts

(* The provider takes the request. A Completed acknowledges every receipt
   the run carried; any other end keeps them. *)
Accept ==
  /\ phase = "sending"
  /\ Request <= Window
  /\ phase' = "idle"
  /\ receipts' \in {0, receipts}
  /\ UNCHANGED << fixed, form, history >>

(* A typed size refusal. The carrier hook switches the form and the run
   asks again at the same capacity. *)
RefuseAndSwitch ==
  /\ phase = "sending"
  /\ Request > Window
  /\ SwitchShortens
  /\ form' = "address"
  /\ UNCHANGED << receipts, fixed, history, phase >>

(* The hook answered Unchanged, so the walk halves history. *)
RefuseAndShrink ==
  /\ phase = "sending"
  /\ Request > Window
  /\ ~SwitchShortens
  /\ history > 0
  /\ history' = history \div 2
  /\ UNCHANGED << receipts, fixed, form, phase >>

(* The floor is refused and the hook has nothing left to change. *)
RefuseAtFloor ==
  /\ phase = "sending"
  /\ Request > Window
  /\ ~SwitchShortens
  /\ history = 0
  /\ phase' = "locked"
  /\ UNCHANGED << receipts, fixed, form, history >>

Next ==
  \/ Retain
  \/ StartRun
  \/ Accept
  \/ RefuseAndSwitch
  \/ RefuseAndShrink
  \/ RefuseAtFloor

SpecClean == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

(* A run is fenced only when the smallest request it can send is over the
   window. That case is the operator's, as the bounded-restart RFC says; the
   larger of FixedSizes makes the clean model reach it. *)
NoLockWhileFloorFits == (phase = "locked") => ~FloorFits

(* Receipts leave the outbox only when the provider took the request: the
   fix never drops results to make room. *)
ReceiptsLeaveOnlyOnAccept ==
  [][(receipts' < receipts) => (phase = "sending" /\ phase' = "idle")]_vars

(***************************************************************************)
(* The walk before this RFC: a size refusal goes to history alone.         *)
(***************************************************************************)
RefuseIgnoringCarrier ==
  /\ phase = "sending"
  /\ Request > Window
  /\ IF history > 0
       THEN /\ history' = history \div 2
            /\ UNCHANGED << receipts, fixed, form, phase >>
       ELSE /\ phase' = "locked"
            /\ UNCHANGED << receipts, fixed, form, history >>

NextBuggy == Next \/ RefuseIgnoringCarrier

SpecBuggy == Init /\ [][NextBuggy]_vars

=============================================================================
