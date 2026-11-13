(** Pure trust decision for one already-collected Keeper runtime snapshot.

    This module does no I/O, time observation, logging, or synchronization.
    The effect shell decodes external JSON/options into [raw], calls [decide]
    once, and projects the returned model at the HTTP/dashboard boundary. *)

type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class : Keeper_status_bridge_blocker.runtime_blocker_class option
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind
      * Keeper_execution_receipt.operator_disposition_reason)
        option
  ; status_attention : Keeper_attention_reason.t option
  (** What {!Keeper_status_bridge.attention_of_surface} decided for the
      Keeper's status surface. *)
  ; terminal_next_human_action : string option
  }

(** Why the snapshot shows its disposition. Either the snapshot's own verdict
    (from the approval queue, a runtime blocker, or a row the dashboard could
    not build) or the reason of the receipt it shows. *)
type disposition_reason =
  | Healthy
  | Approval_queue_unreadable
  | Pending_operator_decision
  | Runtime_blocker of Keeper_status_bridge_blocker.runtime_blocker_class
  (** Shown as the class's own name
      ({!Keeper_status_bridge_blocker.runtime_blocker_class_to_string}), except
      an unresolved fiber, which shows as [critical_block]. *)
  | Keeper_dashboard_worker_exception
  | Receipt_reason of Keeper_execution_receipt.operator_disposition_reason

val all_of_disposition_reason : disposition_reason list
(** Every reason, in declaration order: each blocker class and each receipt
    reason is its own entry. *)

val disposition_reason_to_wire : disposition_reason -> string
(** The [disposition_reason] field of the trust JSON, and its
    [attention_reason] when the status surface gives none. Two reasons can
    write one string (a blocker class and a receipt reason share
    [runtime_exhausted]). The dashboard labels these strings with
    [attentionReasonLabel].
    [dashboard/src/api/fixtures/keeper-trust-disposition-reasons.json] holds
    what this function writes; a test here checks it against
    {!all_of_disposition_reason}, and the dashboard's test checks that every
    string in it has a label. *)

(** Why the snapshot needs attention: the status surface's reason, the
    disposition's own reason, or the error text of a dashboard row that could
    not be built. *)
type attention_reason =
  | Status_attention of Keeper_attention_reason.t
  | Disposition_attention of disposition_reason
  | Dashboard_worker_error of string

val attention_reason_to_wire : attention_reason -> string

type t =
  { disposition : Keeper_trust_disposition.t
  ; disposition_reason : disposition_reason
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind
      * Keeper_execution_receipt.operator_disposition_reason)
        option
  (** The operator disposition kind and reason of the receipt the snapshot
      shows, parsed once where the receipt is read:
      [raw.receipt_operator_disposition] when the
      approval queue reads empty. [None] when the snapshot shows its own
      verdict instead (a pending approval, an unreadable approval queue, or no
      receipt in [raw]): it has no classifier of its own, so it reports no
      operator disposition rather than a guessed one. While a runtime blocker
      is active, the effect shell passes no receipt in [raw]
      ([Keeper_runtime_trust_snapshot]), so the blocker's verdict shows and
      this is [None]. *)
  ; needs_attention : bool
  ; attention_reason : attention_reason option
  ; next_human_action : string option
  }

val decide : raw -> t
(** Resolve the display/operator disposition and attention contract exactly
    once from immutable observations. *)
