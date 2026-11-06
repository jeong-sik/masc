open Keeper_tool_shared_runtime
open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared
open Keeper_tool_filesystem_runtime_write_types
open Keeper_tool_filesystem_runtime_capability_failure

let created_directory_stage_to_string = function
  | Create_directory -> "create_directory"
  | Inspect_created_directory -> "inspect_created_directory"
  | Acquire_directory_capability -> "acquire_directory_capability"
  | Validate_directory_capability -> "validate_directory_capability"
  | Apply_directory_permissions -> "apply_directory_permissions"
;;

let created_directory_target_effect_to_string = function
  | Directory_unchanged -> "directory_unchanged"
  | Directory_created_validated -> "directory_created_validated"
  | Directory_created_requested_mode -> "directory_created_requested_mode"
  | Directory_state_unknown -> "directory_state_unknown"
;;

let created_directory_failure_cause_to_string = function
  | Directory_posix_descriptor_unavailable -> "POSIX descriptor unavailable"
  | Directory_unexpected_resource_kind kind ->
    Format.asprintf "unexpected resource kind: %a" Eio.File.Stat.pp_kind kind
  | Directory_resource_identity_changed -> "directory resource identity changed"
  | Directory_operation_failed { exception_; _ } -> Printexc.to_string exception_
;;

let created_directory_failure_json failure =
  `Assoc
    [ "stage", `String (created_directory_stage_to_string failure.stage)
    ; "cause", `String (created_directory_failure_cause_to_string failure.cause)
    ]
;;

let created_directory_sync_outcome_json = function
  | Directory_sync_not_attempted -> `Assoc [ "status", `String "not_attempted" ]
  | Directory_sync_succeeded -> `Assoc [ "status", `String "succeeded" ]
  | Directory_sync_failed error ->
    `Assoc
      [ "status", `String "failed"
      ; "failure", capability_write_failure_json error.failure
      ; ( "cleanup_failures"
        , `List (List.map capability_write_failure_json error.cleanup_failures) )
      ]
;;

let created_directory_commit_json commit =
  `Assoc
    [ "component", `String commit.component
    ; ( "target_effect"
      , `String (created_directory_target_effect_to_string commit.target_effect) )
    ; ( "primary_failure"
      , match commit.primary_failure with
        | None -> `Null
        | Some failure -> created_directory_failure_json failure )
    ; "child_sync", created_directory_sync_outcome_json commit.child_sync
    ; "parent_sync", created_directory_sync_outcome_json commit.parent_sync
    ]
;;

let created_parent_effects_json created_parents =
  `List (List.map created_directory_commit_json created_parents)
;;

let created_directory_sync_observation_json = function
  | Directory_sync_not_attempted -> `String "not_attempted"
  | Directory_sync_succeeded -> `String "succeeded"
  | Directory_sync_failed _ -> `String "failed"
;;

let created_parent_effect_observation_json commit =
  `Assoc
    [ ( "target_effect"
      , `String (created_directory_target_effect_to_string commit.target_effect) )
    ; "child_sync", created_directory_sync_observation_json commit.child_sync
    ; "parent_sync", created_directory_sync_observation_json commit.parent_sync
    ]
;;

let created_parent_effect_observations_json created_parents =
  `List (List.map created_parent_effect_observation_json created_parents)
;;

let capability_write_error_payload
      ~target
      ~created_parents
      (error : Fs_compat.capability_write_error)
  =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_write_operation"
        , `String
            (Fs_compat.capability_write_operation_to_string error.operation) )
      ; ( "filesystem_target_effect"
        , `String
            (Fs_compat.capability_write_target_effect_to_string
               error.target_effect) )
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; ( "filesystem_primary_failure"
        , capability_write_primary_failure_json error.primary_failure )
      ; ( "filesystem_cleanup_failures"
        , `List
            (List.map
               capability_write_cleanup_failure_json
               error.cleanup_failures) )
      ]
    (fs_guidance_text Publication_failed)
;;

let created_directory_commit_payload ~target ~created_parents commit =
  error_json
    ~fields:
      [ "path", `String target
      ; ( "filesystem_created_parent_effects"
        , created_parent_effects_json created_parents )
      ; "filesystem_directory_component", `String commit.component
      ; ( "filesystem_directory_target_effect"
        , `String
            (created_directory_target_effect_to_string commit.target_effect) )
      ; ( "filesystem_directory_primary_failure"
        , match commit.primary_failure with
          | None -> `Null
          | Some failure -> created_directory_failure_json failure )
      ; ( "filesystem_directory_child_sync"
        , created_directory_sync_outcome_json commit.child_sync )
      ; ( "filesystem_directory_parent_sync"
        , created_directory_sync_outcome_json commit.parent_sync )
      ]
    (fs_guidance_text Directory_publication_failed)
;;

let observe_created_directory_failure_backtrace
      ~keeper_name
      ~target
      failure
  =
  match failure.cause with
  | Directory_operation_failed { exception_; backtrace } ->
    Log.Keeper.error
      ~keeper_name
      "WRITE_AUDIT: directory publication operation failed path=%s stage=%s error=%s backtrace=%s"
      target
      (created_directory_stage_to_string failure.stage)
      (Printexc.to_string exception_)
      (Printexc.raw_backtrace_to_string backtrace)
  | ( Directory_posix_descriptor_unavailable
    | Directory_unexpected_resource_kind _
    | Directory_resource_identity_changed ) -> ()
;;

let observe_created_directory_sync_outcome ~keeper_name ~target = function
  | Directory_sync_not_attempted | Directory_sync_succeeded -> ()
  | Directory_sync_failed error ->
    observe_capability_directory_sync_error ~keeper_name ~target error
;;

let observe_created_directory_commit ~keeper_name ~target commit =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: directory publication outcome path=%s component=%s target_effect=%s child_sync=%s parent_sync=%s"
    target
    commit.component
    (created_directory_target_effect_to_string commit.target_effect)
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.child_sync))
    (Yojson.Safe.to_string
       (created_directory_sync_outcome_json commit.parent_sync));
  Option.iter
    (observe_created_directory_failure_backtrace ~keeper_name ~target)
    commit.primary_failure;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.child_sync;
  observe_created_directory_sync_outcome
    ~keeper_name
    ~target
    commit.parent_sync
;;
