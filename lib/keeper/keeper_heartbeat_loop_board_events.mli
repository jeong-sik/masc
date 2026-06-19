(** Pending board-event collection for the keeper heartbeat loop. *)

val should_collect_board_events :
  proactive_warmup_elapsed:bool -> paused:bool -> bool
(** Pure gate deciding whether this cycle may collect board events (which
    advances the per-keeper cursor as a side effect). True only when the keeper
    has warmed up and is not paused; a paused keeper must not advance its cursor
    past posts it cannot act on this cycle. *)

val collect_keepalive_board_events :
  ctx:'a Keeper_types_profile.context ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  proactive_warmup_elapsed:bool ->
  Keeper_world_observation.pending_board_event list * Keeper_meta_contract.keeper_meta
(** Collect pending board events after proactive warmup has elapsed. *)
