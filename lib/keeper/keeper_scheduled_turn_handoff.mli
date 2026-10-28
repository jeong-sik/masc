(** Scheduled sources waiting for a turn, independent of chat queue order. *)
(** Authoritative durable read, offloaded through the shared executor. *)
val pending : base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, string) result
val successors : intake:Keeper_heartbeat_source_batch.t ->
  base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, string) result
(** Re-read the durable queue and return the scheduled entries that arrived
    after [intake] read it ({!Keeper_heartbeat_source_batch.arrived_since_intake}).
    Retention, deferral or reprioritization does not make an old occurrence
    new; withdrawing and reinserting it does. {!Keeper_heartbeat_source_batch.empty}
    has no intake read, so every pending scheduled entry is returned. *)
type request_error =
  | Queue_unavailable of string
  | Owner_unavailable of Keeper_owner_registry.command_error

val request : intake:Keeper_heartbeat_source_batch.t ->
  base_path:string -> keeper_name:string ->
  (Keeper_event_queue_state.pending_selection list, request_error) result
(** At an owned post-tool boundary, request a handoff for the {!successors}
    of this turn's intake. Waiting work that intake already saw, admitted or
    not (including a suspended predecessor), does not preempt its successor.
    No ACK,
    reprioritization or new copy of the input is written. A negative live
    queue hint avoids durable I/O on the ordinary post-tool hot path. *)
