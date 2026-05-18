(** Fail-open cascade routing helpers for keeper turn budgeting. *)

open Keeper_types
open Keeper_exec_context
module EC = Keeper_error_classify

let public_profile_name name =
  let name = String.trim name in
  let tier_group_prefix = "tier-group." in
  let tier_prefix = "tier." in
  if String.starts_with ~prefix:tier_group_prefix name
  then
    String.sub
      name
      (String.length tier_group_prefix)
      (String.length name - String.length tier_group_prefix)
  else if String.starts_with ~prefix:tier_prefix name
  then
    String.sub
      name
      (String.length tier_prefix)
      (String.length name - String.length tier_prefix)
  else name

let fail_open_rotation_cascades_from_catalog
      ?(excluded_targets : string list = [])
      ~(catalog_names : string list)
      ~(keeper_assignable : string list)
      ()
  =
  if catalog_names = []
  then None
  else (
    let excluded_targets =
      excluded_targets |> List.map public_profile_name |> dedupe_keep_order
    in
    let is_reserved_default name =
      String.equal name (Keeper_config.default_cascade_name ())
    in
    let is_keeper_assignable name =
      List.exists (String.equal name) keeper_assignable
    in
    let is_excluded name =
      List.exists (String.equal (public_profile_name name)) excluded_targets
    in
    match
      catalog_names
      |> List.filter (fun name ->
        (is_reserved_default name || is_keeper_assignable name)
        && not (is_excluded name))
      |> dedupe_keep_order
    with
    | [] -> None
    | candidates -> Some candidates)

let keeper_fail_open_route_uses =
  [ Keeper_cascade_profile.Keeper_turn
  ; Keeper_cascade_profile.Phase_recovery
  ; Keeper_cascade_profile.Phase_buffer
  ; Keeper_cascade_profile.Tool_required
  ]

let is_keeper_fail_open_route_use use =
  List.exists (( = ) use) keeper_fail_open_route_uses

let route_target_for_use use =
  try Some (Keeper_cascade_profile.cascade_name_for_use use |> public_profile_name)
  with
  | Failure _ -> None

let active_fail_open_excluded_route_targets () =
  let keeper_route_targets =
    keeper_fail_open_route_uses
    |> List.filter_map route_target_for_use
    |> dedupe_keep_order
  in
  Cascade_routes.all_logical_uses
  |> List.filter (fun use -> not (is_keeper_fail_open_route_use use))
  |> List.filter_map route_target_for_use
  |> List.filter (fun target ->
    not (List.exists (String.equal target) keeper_route_targets))
  |> dedupe_keep_order

let active_fail_open_rotation_cascades () =
  fail_open_rotation_cascades_from_catalog
    ~excluded_targets:(active_fail_open_excluded_route_targets ())
    ~catalog_names:(Keeper_cascade_profile.catalog_names ())
    ~keeper_assignable:(Keeper_cascade_profile.keeper_catalog_names ())
    ()

let tool_required_rotation_cascade_name () =
  try
    Keeper_cascade_profile.cascade_name_for_use Keeper_cascade_profile.Tool_required
  with
  | Failure _ -> Keeper_config.tool_use_strict_cascade_name

let next_fail_open_cascade_for_turn
      ?rotation_cascades
      ~(base_cascade : string)
      ~(effective_cascade : string)
      ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
      ~(attempted_cascades : string list)
      (err : Agent_sdk.Error.sdk_error)
  : EC.degraded_retry option
  =
  let fallback_hint =
    Keeper_cascade_profile.fallback_cascade_for effective_cascade
  in
  let rotation_cascades =
    match tool_requirement, rotation_cascades with
    | Keeper_agent_tool_surface.Required, Some _ ->
      Some (dedupe_keep_order [ base_cascade; tool_required_rotation_cascade_name () ])
    | _ -> rotation_cascades
  in
  EC.degraded_rotation_after_recoverable_error
    ?rotation_cascades
    ?fallback_hint
    ~base_cascade
    ~effective_cascade
    ~tool_requirement
    ~attempted_cascades
    err

let sdk_error_kind = function
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Provider _ -> "provider"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.A2a _ -> "a2a"
  | Agent_sdk.Error.Internal _ -> "internal"

let record_turn_failure_stress
      ~(meta : keeper_meta)
      ~(is_auto_recoverable : bool)
      ~(consecutive : int)
      ~(threshold : int)
      ~(err : Agent_sdk.Error.sdk_error)
  : unit
  =
  let room_id =
    match meta.joined_room_ids with
    | room_id :: _ -> room_id
    | [] -> ""
  in
  Agent_stress.record
    { agent_name = meta.name
    ; room_id
    ; kind =
        Turn_failure
          { consecutive
          ; threshold
          ; counted_toward_crash = not is_auto_recoverable
          ; recoverable = is_auto_recoverable
          ; error_kind = Some (Agent_stress.error_kind_of_string (sdk_error_kind err))
          }
    ; (* NDT-OK: stress telemetry records wall-clock observation time only;
         failure classification is derived above. *)
      timestamp = Unix.gettimeofday ()
    }
