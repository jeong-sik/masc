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

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (Keeper_event_queue.stimulus * Yojson.Safe.t, string) result
