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
  | Runtime_exhausted
  | Critical_block
  | Unknown_runtime_blocker
  | Keeper_dashboard_worker_exception
  | Receipt_reason of Keeper_execution_receipt.operator_disposition_reason

val disposition_reason_to_wire : disposition_reason -> string

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
