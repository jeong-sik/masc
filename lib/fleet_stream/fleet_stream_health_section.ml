type error =
  | Not_measured of { status : string }
  | Scan_failed of Fleet_stream.degraded_reason
  | Unreadable of string

let error_to_string = function
  | Not_measured { status } ->
    Printf.sprintf "the fleet has not been measured (%s)" status
  | Scan_failed Fleet_stream.Scan_timed_out -> "the fleet scan timed out"
  | Scan_failed Fleet_stream.Scan_failed -> "the fleet scan failed"
  | Unreadable detail -> detail
;;

open Result.Syntax

let unreadable fmt = Printf.ksprintf (fun detail -> Error (Unreadable detail)) fmt

(* The section's key names, as the scan writes them. *)
module Key = struct
  let section = "keeper_fleet_safety"
  let schema = "schema"
  let status = "status"
  let component_timed_out = "component_timed_out"
  let blocker = "blocker"
  let operator_action_required = "operator_action_required"
  let bootable_count = "bootable_keeper_count"
  let running_count = "running_keeper_fiber_count"
  let executable_count = "executable_keeper_fiber_count"
  let failing_count = "failing_keeper_fiber_count"
  let recovering_count = "recovering_keeper_fiber_count"
  let turn_configuration_error_count = "turn_configuration_error_keeper_count"

  let official_client_recovery_required_count =
    "official_client_recovery_required_keeper_count"
  ;;

  let paused_count = "paused_keeper_count"
  let target_reaction_capacity = "target_reaction_capacity_count"
  let reaction_capacity_shortfall = "reaction_capacity_shortfall_count"
  let bootable_names = "bootable_keeper_names"
  let running_names = "running_keeper_names"
  let executable_names = "executable_keeper_names"
  let turn_configuration_error_names = "turn_configuration_error_keeper_names"

  let official_client_recovery_required_names =
    "official_client_recovery_required_keeper_names"
  ;;

  let active_task_owner_without_fiber_count =
    "active_task_owner_without_executable_fiber_count"
  ;;

  let completion_authority_pending_count = "completion_authority_pending_task_count"
  let active_task_owner_scan_error_count = "active_task_owner_scan_error_count"
end

let member section key = List.assoc_opt key section

let string_field section key =
  match member section key with
  | Some (`String value) -> Ok value
  | Some _ -> unreadable "%s.%s is not a string" Key.section key
  | None -> unreadable "%s has no field %s" Key.section key
;;

let bool_field section key =
  match member section key with
  | Some (`Bool value) -> Ok value
  | Some _ -> unreadable "%s.%s is not a boolean" Key.section key
  | None -> unreadable "%s has no field %s" Key.section key
;;

let count_field section key =
  match member section key with
  | Some (`Int value) when value >= 0 -> Ok value
  | Some (`Int _) -> unreadable "%s.%s is negative" Key.section key
  | Some _ -> unreadable "%s.%s is not an integer" Key.section key
  | None -> unreadable "%s has no field %s" Key.section key
;;

let names_field section key =
  match member section key with
  | Some (`List items) ->
    let rec strings acc = function
      | [] -> Ok (Fleet_stream.Names.of_list acc)
      | `String name :: rest -> strings (name :: acc) rest
      | _ :: _ -> unreadable "%s.%s holds something that is not a string" Key.section key
    in
    strings [] items
  | Some _ -> unreadable "%s.%s is not a list" Key.section key
  | None -> unreadable "%s has no field %s" Key.section key
;;

let blocker_field section =
  match member section Key.blocker with
  | Some `Null -> Ok None
  | Some (`String word) ->
    (match Keeper_fleet_blocker.of_wire_name word with
     | Some blocker -> Ok (Some blocker)
     | None -> unreadable "%s.%s names no blocker this build knows: %s" Key.section Key.blocker word)
  | Some _ -> unreadable "%s.%s is not a string or null" Key.section Key.blocker
  | None -> unreadable "%s has no field %s" Key.section Key.blocker
;;

let fleet_of_section section : (Fleet_stream.fleet, error) result =
  let* status_word = string_field section Key.status in
  let* fs_status =
    match Keeper_fleet_grade.of_wire_name status_word with
    | Some grade -> Ok grade
    | None ->
      unreadable "%s.%s names no grade this build knows: %s" Key.section Key.status
        status_word
  in
  let* fs_blocker = blocker_field section in
  let* fs_operator_action_required = bool_field section Key.operator_action_required in
  let* fs_bootable_count = count_field section Key.bootable_count in
  let* fs_running_count = count_field section Key.running_count in
  let* fs_executable_count = count_field section Key.executable_count in
  let* fs_failing_count = count_field section Key.failing_count in
  let* fs_recovering_count = count_field section Key.recovering_count in
  let* fs_turn_configuration_error_count =
    count_field section Key.turn_configuration_error_count
  in
  let* fs_official_client_recovery_required_count =
    count_field section Key.official_client_recovery_required_count
  in
  let* fs_paused_count = count_field section Key.paused_count in
  let* fs_target_reaction_capacity = count_field section Key.target_reaction_capacity in
  let* fs_reaction_capacity_shortfall =
    count_field section Key.reaction_capacity_shortfall
  in
  let* fs_bootable_names = names_field section Key.bootable_names in
  let* fs_running_names = names_field section Key.running_names in
  let* fs_executable_names = names_field section Key.executable_names in
  let* fs_turn_configuration_error_names =
    names_field section Key.turn_configuration_error_names
  in
  let* fs_official_client_recovery_required_names =
    names_field section Key.official_client_recovery_required_names
  in
  let* fs_active_task_owner_without_fiber_count =
    count_field section Key.active_task_owner_without_fiber_count
  in
  let* fs_completion_authority_pending_count =
    count_field section Key.completion_authority_pending_count
  in
  let* fs_active_task_owner_scan_error_count =
    count_field section Key.active_task_owner_scan_error_count
  in
  Ok
    { Fleet_stream.fs_status
    ; fs_blocker
    ; fs_operator_action_required
    ; fs_bootable_count
    ; fs_running_count
    ; fs_executable_count
    ; fs_failing_count
    ; fs_recovering_count
    ; fs_turn_configuration_error_count
    ; fs_official_client_recovery_required_count
    ; fs_paused_count
    ; fs_target_reaction_capacity
    ; fs_reaction_capacity_shortfall
    ; fs_bootable_names
    ; fs_running_names
    ; fs_executable_names
    ; fs_turn_configuration_error_names
    ; fs_official_client_recovery_required_names
    ; fs_active_task_owner_without_fiber_count
    ; fs_completion_authority_pending_count
    ; fs_active_task_owner_scan_error_count
    }
;;

let fleet_of_health_fields fields =
  match List.assoc_opt Key.section fields with
  | None -> unreadable "the health snapshot has no %s section" Key.section
  | Some (`Assoc section) ->
    (match member section Key.schema with
     | Some (`String schema) when String.equal schema Keeper_fleet_blocker.reading_schema ->
       fleet_of_section section
     | Some (`String schema) ->
       unreadable "%s schema %S is not %S" Key.section schema
         Keeper_fleet_blocker.reading_schema
     | Some _ -> unreadable "%s.%s is not a string" Key.section Key.schema
     | None ->
       (* No schema: the placeholder the snapshot shows before it has a reading,
          which has a status and says whether the refresh ran out of time. A
          section with neither is not a placeholder, and one that is a reading
          without its schema must not pass for one. *)
       (match member section Key.status, member section Key.component_timed_out with
        | Some (`String ("warming" as status)), Some (`Bool false) ->
          Error (Not_measured { status })
        | Some (`String ("warming" | "error" | "timeout" | "unavailable")),
          Some (`Bool true) -> Error (Scan_failed Fleet_stream.Scan_timed_out)
        | Some (`String "timeout"), Some (`Bool false) ->
          Error (Scan_failed Fleet_stream.Scan_timed_out)
        | Some (`String ("error" | "unavailable")), Some (`Bool false) ->
          Error (Scan_failed Fleet_stream.Scan_failed)
        | None, _ | Some _, _ ->
          unreadable "%s has neither a schema nor the fields of the placeholder"
            Key.section))
  | Some _ -> unreadable "%s is not an object" Key.section
;;
