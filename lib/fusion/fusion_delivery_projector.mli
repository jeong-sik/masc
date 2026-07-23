(** Projection boundary between the generic Keeper async lifecycle and
    producer-specific Fusion delivery. *)

type projection_error =
  | Invalid_request_id of string
  | Obligation_unavailable of Fusion_delivery_obligation.error
  | Identity_mismatch of string
  | Non_durable_settlement
  | Ambiguous_settlement
  | Nonterminal_status of Keeper_msg_async.request_status
  | Evidence_unavailable
  | Evidence_invalid of string
  | Projection_failed of string
  | Obligation_removal_failed of Fusion_delivery_obligation.error

val projection_error_to_string : projection_error -> string

val projection_error_failure_code : projection_error -> string
(** Sink failure code derived from the typed error. Only errors delivered
    through [Fusion_sink.emit_failure] have a code (currently
    [Evidence_unavailable]); any other error raises [Invalid_argument]. *)

val on_worker_settled :
  base_path:string -> Keeper_msg_async.worker_settlement -> unit
(** Project an exact durable settlement. Any ambiguity or delivery failure is
    logged and leaves the obligation available for startup reconciliation. *)

type recovery_record_error =
  { request_id : string option
  ; detail : string
  }

type recovery_report =
  { examined : int
  ; projected : int
  ; pending : int
  ; record_errors : recovery_record_error list
  ; staging_cleanup : Fs_compat.atomic_orphan_cleanup_report
  }

val recover_startup :
  base_path:string -> (recovery_report, Fusion_delivery_obligation.error) result
(** With producer writes quiesced by startup ownership, reconcile atomic
    staging orphans and all producer obligations against canonical durable
    terminal request truth. Successful projections remove their exact
    obligation; pending, preserved, or malformed records remain explicit. *)
