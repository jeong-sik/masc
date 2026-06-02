(** Pending board-event collection for the keeper heartbeat loop. *)

val collect_keepalive_board_events :
  ctx:'a Keeper_types_profile.context ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  proactive_warmup_elapsed:bool ->
  Keeper_world_observation.pending_board_event list * Keeper_meta_contract.keeper_meta
(** Collect pending board events after proactive warmup has elapsed. *)
