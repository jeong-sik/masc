(** Keeper_turn_up_update — keeper reconfiguration handler.

    Updates an existing keeper's meta record from the parsed args of
    a [masc_keeper_up] tool call. Pairs with [Keeper_turn_up_create]
    for the new-keeper path. *)

(** What happened to the running keepalive lane after a published update. *)
type runtime_sync =
  | Lane_restarted
      (** The lane was stopped and started again on the updated meta. *)
  | Deferred_until_turn_end of Keeper_owner.turn_in_flight
      (** A turn held the keeper's slot, so the lane was left running. The
          owner already carries the published profile: the turn in flight
          finishes on the meta it was admitted with and the next admitted
          turn reads the new one. Nothing needs to be resent. *)

val runtime_sync_to_wire : runtime_sync -> string
(** ["lane_restarted"] or ["deferred_until_turn_end"]. *)

type update_outcome =
  | Runtime_synced of
      { result : Keeper_types_profile.tool_result
      ; runtime_sync : runtime_sync
      }
      (** The configuration was committed and published. [result] is a
          success carrying [runtime_sync] and the updated [meta]. *)
  | Update_refused of Keeper_types_profile.tool_result
      (** Any failure: CAS conflict, persistence, publication, or a lane
          restart that failed. The error payload says which, and its
          [keeper_config_write] metadata says whether the write applied. *)

val update_keeper_outcome :
  ?preserve_prompt_defaults:bool ->
  expected_config_revision:Keeper_turn_up_config_persistence.config_revision ->
  _ Keeper_types_profile.context ->
  Keeper_turn_up_args.parsed_args ->
  Keeper_meta_contract.keeper_meta ->
  update_outcome
(** Same update as {!update_keeper}, keeping the runtime-sync outcome typed
    for callers that answer differently per outcome. *)

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

type lane_swap_refusal =
  | Swap_turn_in_flight of Keeper_owner.turn_in_flight
      (** A turn holds the slot; the lane was not touched. *)
  | Swap_failed of Keeper_types_profile.tool_result
      (** The shutdown reservation itself failed. *)

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
  , lane_swap_refusal )
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
