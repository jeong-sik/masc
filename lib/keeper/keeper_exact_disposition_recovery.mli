(** Restart composition root for exact source dispositions.

    Checkpoint I/O stays above [masc.keeper_runtime]. The persistence boundary
    receives only one exact current reference and performs WAL replay, exact
    finalization, and generic registration recovery in that order under the
    queue owner's durable lock. *)

val prepare_registration_result :
  base_path:string ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  settled_at:float ->
  (Keeper_event_queue.t, string) result
