(** Deterministic projection from keeper continuity snapshots to working state. *)

val of_state_snapshot :
  keeper_name:string ->
  trace_id:string ->
  keeper_turn_id:int ->
  updated_at_iso:string ->
  updated_at_unix:float ->
  Keeper_memory_policy.keeper_state_snapshot ->
  Keeper_working_state.t

val active_open_loop_count_of_state_snapshot :
  Keeper_memory_policy.keeper_state_snapshot -> int
