(** Pure trust decision for one already-collected Keeper runtime snapshot.

    This module does no I/O, time observation, logging, or synchronization.
    The effect shell decodes external JSON/options into [raw], calls [decide]
    once, and projects the returned model at the HTTP/dashboard boundary. *)

type approval_queue =
  | Approval_queue_available of int
  | Approval_queue_unavailable

type raw =
  { approval_queue : approval_queue
  ; runtime_blocker_class : string option
  ; runtime_blocker_summary : string option
  ; receipt_operator_disposition : (string * string) option
  ; attention_needs_attention : bool
  ; attention_reason : string option
  ; attention_next_human_action : string option
  ; terminal_next_human_action : string option
  }

type t =
  { disposition : string
  ; disposition_reason : string
  ; operator_disposition : string
  ; operator_disposition_reason : string
  ; needs_attention : bool
  ; attention_reason : string option
  ; next_human_action : string option
  }

val decide : raw -> t
(** Resolve the display/operator disposition and attention contract exactly
    once from immutable observations. *)
