type request =
  (* Cancellation and transfer target one durable source incarnation, so an
     unrelated queue revision change must not invalidate them. Reprioritize
     rewrites queue order and therefore retains the queue-wide CAS revision. *)
  | Cancel of
      { queue_index : int
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { queue_index : int
      ; source_incarnation : int64
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { expected_revision : int64
      ; queue_index : int
      ; source_incarnation : int64
      ; urgency : Keeper_event_queue.urgency
      }

val pending_selection_at :
  queue_index:int ->
  Keeper_event_queue_state.pending_selection list ->
  Keeper_event_queue_state.pending_selection option

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (Keeper_event_queue.stimulus * Yojson.Safe.t, string) result
