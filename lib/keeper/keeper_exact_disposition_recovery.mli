(** Restart composition root for exact source dispositions.

    The persistence boundary performs WAL replay, terminal exact disposition
    finalization, and generic registration recovery in that order under the
    queue owner's durable lock. Checkpoint-success reconciliation is outside
    this boundary. *)

val prepare_registration_result :
  base_path:string ->
  keeper_name:string ->
  trace_id:Keeper_id.Trace_id.t ->
  settled_at:float ->
  (Keeper_event_queue.t, string) result
