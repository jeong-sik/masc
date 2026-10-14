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
      (Keeper_execution_receipt.operator_disposition_kind * string) option
  ; status_attention : Keeper_attention_reason.t option
  (** What {!Keeper_status_bridge.attention_of_surface} decided for the
      Keeper's status surface. *)
  ; terminal_next_human_action : string option
  }

type t =
  { disposition : Keeper_trust_disposition.t
  ; disposition_reason : string
  ; receipt_operator_disposition :
      (Keeper_execution_receipt.operator_disposition_kind * string) option
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
  ; attention_reason : string option
  ; next_human_action : string option
  }

val decide : raw -> t
(** Resolve the display/operator disposition and attention contract exactly
    once from immutable observations. *)
