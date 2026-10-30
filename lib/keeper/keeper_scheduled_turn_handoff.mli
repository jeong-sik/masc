(** Scheduled sources waiting for a turn, independent of chat queue order. *)
(** Authoritative durable read, offloaded through the shared executor. *)
val pending : base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, string) result
