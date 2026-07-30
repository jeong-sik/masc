type request =
  (* Cancellation and transfer combine the admission cohort with an exact
     snapshot SHA, so an unrelated queue revision change does not invalidate
     them and a same-cohort index shift cannot alias another row. Reprioritize
     rewrites queue order and therefore retains the queue-wide CAS revision. *)
  | Cancel of
      { queue_index : int
      ; source_incarnation : int64
      ; source_snapshot_sha256 : string
      ; operator_operation_id : string
      ; reason : string
      }
  | Transfer of
      { queue_index : int
      ; source_incarnation : int64
      ; source_snapshot_sha256 : string
      ; operator_operation_id : string
      ; target_keeper : string
      }
  | Reprioritize of
      { expected_revision : int64
      ; queue_index : int
      ; source_incarnation : int64
      ; urgency : Keeper_event_queue.urgency
      }

val run :
  config:Workspace.config ->
  keeper_name:string ->
  request ->
  (Keeper_event_queue.stimulus * Yojson.Safe.t, string) result
