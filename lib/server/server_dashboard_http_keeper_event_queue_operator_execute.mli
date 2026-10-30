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

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (audit_source option * Yojson.Safe.t, string) result
