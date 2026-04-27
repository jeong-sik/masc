(** Keeper_turn_up_update — keeper reconfiguration handler.

    Updates an existing keeper's meta record from the parsed args of
    a [masc_keeper_up] tool call. Pairs with [Keeper_turn_up_create]
    for the new-keeper path. *)

(** Resolve the active goal-ids for an updated keeper: prefer the
    explicit value from parsed args, fall back to profile defaults,
    finally to the existing meta's value. Validates each goal id
    exists in [Goal_store]; returns [Error] listing unknown ids. *)
val resolve_active_goal_ids :
  Coord.config ->
  Keeper_turn_up_args.parsed_args ->
  string list ->
  (string list, string) result

(** Update an existing keeper's meta record. Validates tool-access
    transitions, resolves active goals, applies parsed-arg overrides,
    persists the new meta, and broadcasts state-machine events.
    Returns [(true, json)] on success or [(false, msg)] on validation
    or persistence failure. *)
val update_keeper :
  _ Keeper_types.context ->
  Keeper_turn_up_args.parsed_args ->
  Keeper_types.keeper_meta ->
  Keeper_types.tool_result
