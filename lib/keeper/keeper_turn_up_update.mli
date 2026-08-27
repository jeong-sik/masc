(** Keeper_turn_up_update — keeper reconfiguration handler.

    Updates an existing keeper's meta record from the parsed args of
    a [masc_keeper_up] tool call. Pairs with [Keeper_turn_up_create]
    for the new-keeper path. *)

(** Update an existing keeper's meta record. Validates tool-access
    transitions, resolves active goals, applies parsed-arg overrides,
    persists the new meta, and broadcasts state-machine events.
    Returns structured {!Keeper_types_profile.tool_result}; failures carry their
    message on the typed error payload. *)
val update_keeper :
  ?preserve_prompt_defaults:bool ->
  expected_manifest_revision:Keeper_turn_up_config_persistence.revision ->
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_types_profile.tool_result

val manifest_revision_conflict_of_result :
  Keeper_types_profile.tool_result ->
  Keeper_turn_up_config_persistence.conflict option

val config_publication_rollback_of_result :
  Keeper_types_profile.tool_result -> string option

val config_reconciliation_required_of_result :
  Keeper_types_profile.tool_result -> Yojson.Safe.t option
