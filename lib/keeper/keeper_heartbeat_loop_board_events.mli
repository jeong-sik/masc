(** Pending board-event collection for the keeper heartbeat loop. *)

val should_collect_board_events :
  proactive_warmup_elapsed:bool ->
  paused:bool ->
  approval_pending:bool ->
  keeper_backpressured:bool ->
  provider_cooldown_pending:bool ->
  bool
(** Pure gate deciding whether this cycle may collect board events (which
    advances the per-keeper cursor as a side effect). True only when the keeper
    has warmed up and no known later turn-admission gate would prevent action.
    A blocked keeper must not advance its cursor past posts it cannot act on
    this cycle. *)

val collect_keepalive_board_events :
  ctx:'a Keeper_types_profile.context ->
  meta_current:Keeper_meta_contract.keeper_meta ->
  proactive_warmup_elapsed:bool ->
  approval_pending:bool ->
  keeper_backpressured:bool ->
  provider_cooldown_pending:bool ->
  Keeper_world_observation.pending_board_event list * Keeper_meta_contract.keeper_meta
(** Collect pending board events after proactive warmup has elapsed. *)

val fleet_health_json :
  base_path:string -> keeper_names:string list -> Yojson.Safe.t
(** Fleet health for recent board-event collection failures. A failure means
    the reactive board scanner returned no events because collection raised;
    the next successful collection for that keeper clears the failure. *)

module For_testing : sig
  val reset : unit -> unit

  val record_collection_failure :
    base_path:string -> keeper_name:string -> message:string -> unit

  val clear_collection_failure :
    base_path:string -> keeper_name:string -> unit
end
