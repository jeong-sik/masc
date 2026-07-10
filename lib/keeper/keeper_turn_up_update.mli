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

(** Defense-in-depth gate shared by keeper reconfiguration and direct-turn
    admission. A Blocking in-memory approval owns the keeper lane; after a
    restart, the typed persisted ambiguous-commit blocker keeps that ownership
    until the approval queue has been rehydrated. *)
val paused_state_requires_approval :
  base_path:string -> Keeper_meta_contract.keeper_meta -> bool

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
