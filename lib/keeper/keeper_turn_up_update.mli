(** Keeper_turn_up_update — keeper reconfiguration handler.

    Updates an existing keeper's meta record from the parsed args of
    a [masc_keeper_up] tool call. Pairs with [Keeper_turn_up_create]
    for the new-keeper path. *)

(** Resolve the active goal-ids for an updated keeper: prefer the
    explicit value from parsed args, fall back to profile defaults,
    finally to the existing meta's value. Validates each goal id
    exists in [Goal_store]; returns [Error] listing unknown ids. *)
val resolve_active_goal_ids :
  Workspace.config ->
  Keeper_turn_up_args.parsed_args ->
  string list ->
  (string list, string) result

(** Outcome of {!revival_decision}. *)
type revival_decision = {
  dead_revival_requested : bool;
      (** Route this [masc_keeper_up] call through
          {!Keeper_dead_revival_transaction.revive} instead of the normal
          CAS-merge write path. *)
  clear_pause_state : bool;
      (** Clear [paused], [latched_reason], and [runtime.last_blocker] on
          the updated meta before it is persisted. *)
}

(** Decide the dead-revival / pause-clearing outcome for an existing
    keeper's [masc_keeper_up] call, from its persisted latch/pause state
    alone. Pure and total -- does not read or write the meta store.

    [dead_revival_requested] is true exactly when [latched_reason] is
    [Dead_tombstone], independent of [paused]. The canonical setter
    ([Keeper_shutdown_finalize]'s [dead_tombstone_meta]) always pairs
    [Dead_tombstone] with [paused = true], but a resume writer that clears
    [paused] without clearing the latch can strand a keeper at
    [paused = false] + [Dead_tombstone] (see
    [Keeper_meta_contract.dead_tombstone_pause_violation]). Lifecycle
    admission denies by the latch regardless of [paused], so a stranded
    keeper needs a revival path that does not require [paused = true].

    This does not widen who can call [update_keeper]: [masc_keeper_up] is
    already a general MCP tool ({!Tool_catalog}), registered in
    {!Keeper_tool_surface}'s in-process dispatch, and reachable from the
    dashboard HTTP handler and [masc_keeper_recover]'s automated down/up
    sequence ({!Operator_control}). What it widens is the set of
    legacy-corrupted states that a call, once made, normalizes: previously
    only the canonical [paused = true] + [Dead_tombstone] pairing reached
    the revival transaction; the stranded [paused = false] + [Dead_tombstone]
    split now does too.

    [clear_pause_state] is [paused || dead_revival_requested]: an ordinary
    [masc_keeper_up] call on a keeper that is merely paused resumes it, and
    a dead-revival always clears pause/latch state as well. *)
val revival_decision :
  latched_reason:Keeper_latched_reason.t option ->
  paused:bool ->
  revival_decision

(** Update an existing keeper's meta record. Validates tool-access
    transitions, resolves active goals, applies parsed-arg overrides,
    persists the new meta, and broadcasts state-machine events.
    Returns structured {!Keeper_types_profile.tool_result}; failures carry their
    message on the typed error payload. *)
val update_keeper :
  ?preserve_prompt_defaults:bool ->
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_types_profile.tool_result
