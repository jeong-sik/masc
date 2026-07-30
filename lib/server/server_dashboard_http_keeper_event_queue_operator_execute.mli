type request =
  | Cancel of
      { expected_revision : int64
      ; queue_index : int
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { expected_revision : int64
      ; queue_index : int
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { expected_revision : int64
      ; queue_index : int
      ; urgency : Keeper_event_queue.urgency
      }

val pending_source_at :
  queue_index:int ->
  Keeper_event_queue.t ->
  Keeper_event_queue.stimulus option

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (Keeper_event_queue.stimulus * Yojson.Safe.t, string) result
