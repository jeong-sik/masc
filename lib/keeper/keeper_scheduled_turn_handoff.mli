(** Scheduled sources waiting for a turn, independent of chat queue order. *)
(** Authoritative durable read, offloaded through the shared executor. *)
val pending : base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, string) result
type request_error =
  | Queue_unavailable of string
  | Owner_unavailable of Keeper_owner_registry.command_error

val request : excluding:Keeper_event_queue_state.pending_selection list ->
  base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, request_error) result
(** At an owned post-tool boundary, request a handoff for pending scheduled
    sources not already present in this turn's exact source cohort. No ACK,
    reprioritization or new copy of the input is written. A negative live
    queue hint avoids durable I/O on the ordinary post-tool hot path. *)
