type t =
  | Skill_config_rejected of { diagnostics : Skill_source_config.diagnostic list }
  | Skill_config_unreadable of { detail : string }
  | Skill_source_unreadable of
      { source_id : string
      ; observation : Skill_catalog_snapshot.source_observation
      }
  | Skill_entry_unreadable of
      { reference : Skill_reference.t
      ; path : string
      ; detail : string
      }

type Agent_core.Error.carrier += Task_skill_resolution_error of t

type kind =
  | Config_rejected
  | Config_unreadable
  | Source_unreadable
  | Entry_unreadable

let kind = function
  | Skill_config_rejected _ -> Config_rejected
  | Skill_config_unreadable _ -> Config_unreadable
  | Skill_source_unreadable _ -> Source_unreadable
  | Skill_entry_unreadable _ -> Entry_unreadable
;;

let kind_to_code = function
  | Config_rejected -> "task_skill_config_rejected"
  | Config_unreadable -> "task_skill_config_unreadable"
  | Source_unreadable -> "task_skill_source_unreadable"
  | Entry_unreadable -> "task_skill_entry_unreadable"
;;

let code error = kind_to_code (kind error)

let source_observation_to_string = function
  | Skill_catalog_snapshot.Source_ready _ -> "ready"
  | Skill_catalog_snapshot.Source_missing { resolved_path } ->
    Printf.sprintf "source directory is missing: %s" resolved_path
  | Skill_catalog_snapshot.Source_not_directory { resolved_path; kind = _ } ->
    Printf.sprintf "source path is not a directory: %s" resolved_path
  | Skill_catalog_snapshot.Source_unavailable { resolved_path; operation; detail } ->
    Printf.sprintf "%s failed on %s: %s"
      (Skill_catalog_snapshot.source_operation_to_string operation)
      resolved_path
      detail
  | Skill_catalog_snapshot.Source_unresolved resolution ->
    (match resolution with
     | Skill_source_config.Resolved path ->
       Printf.sprintf "source did not resolve: %s" path
     | Skill_source_config.Anchor_unavailable anchor ->
       Printf.sprintf "source anchor is unavailable: %s"
         (Skill_source_config.anchor_to_string anchor)
     | Skill_source_config.Anchor_invalid { anchor; rejection } ->
       Printf.sprintf "source anchor is invalid: %s: %s"
         (Skill_source_config.anchor_to_string anchor)
         (Skill_source_config.anchor_rejection_to_string rejection)
     | Skill_source_config.Path_rejected rejection ->
       Printf.sprintf "source path is rejected: %s"
         (Skill_source_config.path_rejection_to_string rejection))
;;

let to_string = function
  | Skill_config_rejected { diagnostics } ->
    "Skill configuration is rejected, so Task Skills cannot be resolved: "
    ^ String.concat "; " (List.map Skill_source_config.diagnostic_to_string diagnostics)
  | Skill_config_unreadable { detail } ->
    "Skill configuration is unreadable, so Task Skills cannot be resolved: " ^ detail
  | Skill_source_unreadable { source_id; observation } ->
    Printf.sprintf
      "Skill source %s was not read successfully, so a Task pin into it cannot be told apart from a deleted Skill: %s"
      source_id
      (source_observation_to_string observation)
  | Skill_entry_unreadable { reference; path; detail } ->
    Printf.sprintf "Skill %s could not be read (%s), so its Task pin cannot be told apart from a deleted Skill: %s"
      (Skill_reference.to_yojson reference |> Yojson.Safe.to_string)
      path
      detail
;;

let core_error error =
  Agent_core.Error.Internal_carried
    { message = to_string error
    ; carrier = Task_skill_resolution_error error
    }
;;

let of_core_error = function
  | Agent_core.Error.Internal_carried
      { carrier = Task_skill_resolution_error error; _ } ->
    Some error
  | ( Agent_core.Error.Api _
    | Provider _
    | Agent _
    | Mcp _
    | Config _
    | Serialization _
    | Io _
    | Orchestration _ | Media _
    | Internal _
    | Internal_carried _ ) ->
    None
;;
