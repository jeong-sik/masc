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
  expected_config_revision:Keeper_turn_up_config_persistence.config_revision ->
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_types_profile.tool_result

val config_revision_conflict_code : string
(** The wire code a CAS revision conflict carries — written by the tool-result
    data here and by the dashboard's 409 body, matched by the TUI client and
    the dashboard TS. One definition; consumers that restate the string drift
    silently. (The tool-result data round trip itself is the Tool_result
    boundary contract: the same update serves the keeper tool surface, which
    only sees JSON.) *)

val config_revision_conflict_of_result :
  Keeper_types_profile.tool_result ->
  Keeper_turn_up_config_persistence.conflict option

val config_publication_rollback_of_result :
  Keeper_types_profile.tool_result -> string option

val config_reconciliation_required_of_result :
  Keeper_types_profile.tool_result -> Yojson.Safe.t option

(** Swap a live keeper's lane under the owner-domain fence: stop the old
    lane, persist the updated meta, and start the replacement. Runs on the
    root-switch owner domain when called from a worker domain, so the new
    lane's fibers fork from the owning switch. Exposed for the
    cross-domain swap integration test. *)
val swap_keepalive_lane_fenced :
  'a Keeper_types_profile.context ->
  Keeper_meta_contract.keeper_meta ->
  ( Keeper_keepalive.joined_stop_result
    * Keeper_keepalive.start_keepalive_outcome
  , Keeper_types_profile.tool_result )
  result

module For_testing : sig
  val composite_reconciliation_required_data :
    Keeper_turn_up_config_persistence.composite_reconciliation ->
    Yojson.Safe.t

  val update_keeper_with_apply_profile :
    apply_profile:
      (base_path:string ->
       keeper_name:string ->
       Keeper_owner_reducer.meta_command ->
       ( Keeper_meta_contract.keeper_meta option
       , Keeper_owner_registry.command_error )
       result) ->
    ?preserve_prompt_defaults:bool ->
    expected_config_revision:Keeper_turn_up_config_persistence.config_revision ->
    _ Keeper_types_profile.context ->
    Keeper_turn_up_args.parsed_args ->
    Keeper_meta_contract.keeper_meta ->
    Keeper_types_profile.tool_result
end
