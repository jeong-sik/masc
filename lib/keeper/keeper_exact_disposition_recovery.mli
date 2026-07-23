(** Restart composition root for exact source dispositions.

    The persistence boundary performs WAL replay, terminal exact disposition
    finalization, and generic registration recovery in that order under the
    queue owner's durable lock. *)

val prepare_registration_result :
  base_path:string ->
  keeper_name:string ->
  settled_at:float ->
  (Keeper_event_queue.t, string) result
