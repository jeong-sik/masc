type request =
  | Cancel of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { source_ref : string
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { source_ref : string
      ; source_incarnation : int64
      ; urgency : Keeper_event_queue.urgency
      }

type audit_source =
  { post_id : string
  ; payload_kind : string
  }

type completion =
  | Complete
  | Committed_followup_failed

type outcome =
  { audit_source : audit_source option
  ; response : Yojson.Safe.t
  ; completion : completion
  }

(** [Committed_followup_failed] retains the accepted transition: it must not
    be counted as an unapplied cancellation or blindly retried as fresh work.
    Successful cancellations project their exact outbox receipt before the
    next selected row is admitted. *)

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (outcome, string) result
