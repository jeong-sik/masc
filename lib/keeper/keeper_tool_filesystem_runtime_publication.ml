open Keeper_tool_filesystem_guidance
open Keeper_tool_filesystem_runtime_shared
open Keeper_tool_filesystem_runtime_write_types
open Keeper_tool_filesystem_runtime_test_seams
open Keeper_tool_filesystem_runtime_append
open Keeper_tool_filesystem_runtime_created_directory_report

let rec file_write_attempt_to_execution ~config = function
  | Write_unchanged payload -> Keeper_tool_execution.success_data payload
  | Write_succeeded { payload; file_change_evidence } ->
    let execution = Eio.Cancel.protect (fun () ->
      let result = Tool_result.make_ok ~tool_name:"tool_write_file"
        ~start_time:(Tool_timing.start ()) ~data:payload () in
      Option.iter (fun hook -> hook ()) (Eio.Fiber.get before_result_manifest_key);
      match Tool_bridge.attach_artifact_manifest ~base_path:config.Workspace.base_path result with
      | Ok result -> Keeper_tool_execution.of_tool_result result
      | Error error ->
        Log.Keeper.error "applied filesystem change result manifest unavailable: %s" error.message;
        Keeper_tool_execution.failure_data ~class_:Tool_result.Runtime_failure
          ~effect_disposition:Tool_result.Proven_post_effect
          ~message:"The file change was applied, but its result manifest could not be stored. Read the recorded snapshots or current file; do not repeat the edit."
          payload) in
    (match file_change_evidence with
     | Some evidence ->
       Keeper_tool_execution.with_file_change_evidence evidence execution
     | None -> execution)
  | Write_authorized (authorization, attempt) ->
    file_write_attempt_to_execution ~config attempt
    |> Keeper_tool_execution.with_gate_authorization authorization
  | Write_deferred deferred ->
    Keeper_gate_deferred_payload.to_execution deferred
  | Write_failed { payload; class_ } -> Keeper_tool_execution.failure ~class_ payload
  | Write_failed_data { message; data; class_ } ->
    Keeper_tool_execution.failure_data ~class_ ~message data
;;

let publication_recovery_unavailable_attempt unavailable =
  Write_failed_data
    { message =
        Keeper_publication_recovery_availability.unavailable_to_string unavailable
    ; data =
        Keeper_publication_recovery_availability.unavailable_to_yojson unavailable
    ; class_ = Keeper_publication_recovery_availability.failure_class unavailable
    }
;;

type publication_write_execution =
  | Publication_write_completed
  | Publication_write_effect_observed
  | Publication_write_not_executed
  | Publication_write_indeterminate

type publication_callback_observation =
  { execution : publication_write_execution
  ; publication_result : Yojson.Safe.t
  }

let publication_recovery_cleanup_failed_attempt
      ~keeper_name
      ~target
      ~execution
      ~publication_result
      release_failure
  =
  Log.Keeper.error
    ~keeper_name
    "WRITE_AUDIT: publication recovery lane release failed after callback path=%s write_execution=%s evidence=%s"
    target
    (match execution with
     | Publication_write_completed -> "completed"
     | Publication_write_effect_observed -> "effect_observed"
     | Publication_write_not_executed -> "not_executed"
     | Publication_write_indeterminate -> "indeterminate")
    (Fs_compat.Publication_recovery.lane_release_failure_to_string
       release_failure);
  let message, write_executed =
    match execution with
    | Publication_write_completed -> fs_guidance_text Recovery_lane_committed, `Bool true
    | Publication_write_effect_observed ->
      fs_guidance_text Recovery_lane_effect_observed, `Bool true
    | Publication_write_not_executed ->
      fs_guidance_text Recovery_lane_not_executed, `Bool false
    | Publication_write_indeterminate ->
      fs_guidance_text Recovery_lane_indeterminate, `Null
  in
  let class_ = Tool_result.Runtime_failure in
  Write_failed_data
    { message
    ; data =
        `Assoc
          [ "error", `String "publication_recovery_cleanup_failed"
          ; ( "failure_class"
            , `String (Tool_result.tool_failure_class_to_string class_) )
          ; "state", `String "lane_release_failed"
          ; "detail", `String (fs_guidance_text Recovery_lane_cleanup_detail)
          ; "write_executed", write_executed
          ; "keeper_active", `Bool true
          ; "publication_result", publication_result
          ]
    ; class_
    }
;;

let finish_recovery_guarded_write
      ~keeper_name
      ~target
      ~observe_result
      ~finish
      outcome
  =
  match outcome with
  | Fs_compat.Publication_recovery.Lane_released result -> finish result
  | Fs_compat.Publication_recovery.Lane_release_failed
      { value; release_failure } ->
    let observation = observe_result value in
    let publication_result =
      match finish value with
      | Ok _ -> observation.publication_result
      | Error message ->
        Log.Keeper.error
          ~keeper_name
          "WRITE_AUDIT: publication callback result projection failed before lane release evidence path=%s error=%s"
          target
          message;
        `Assoc
          [ "outcome", `String "projection_failure"
          ; "callback_result", observation.publication_result
          ]
    in
    Ok
      (publication_recovery_cleanup_failed_attempt
         ~keeper_name
         ~target
         ~execution:observation.execution
         ~publication_result
         release_failure)
;;

type publication_effect_observation =
  | Publication_effect_absent
  | Publication_effect_observed
  | Publication_effect_indeterminate

let join_publication_effect_observation left right =
  match left, right with
  | Publication_effect_observed, _ | _, Publication_effect_observed ->
    Publication_effect_observed
  | Publication_effect_indeterminate, _ | _, Publication_effect_indeterminate ->
    Publication_effect_indeterminate
  | Publication_effect_absent, Publication_effect_absent ->
    Publication_effect_absent
;;

let publication_execution_of_effect_observation = function
  | Publication_effect_absent -> Publication_write_not_executed
  | Publication_effect_observed -> Publication_write_effect_observed
  | Publication_effect_indeterminate -> Publication_write_indeterminate
;;

let publication_effect_observation_of_target_effect = function
  | Fs_compat.Target_unchanged -> Publication_effect_absent
  | ( Fs_compat.Target_created
    | Fs_compat.Target_replaced ) ->
    Publication_effect_observed
  | Fs_compat.Target_state_unknown -> Publication_effect_indeterminate
;;

let publication_effect_observation_of_directory_target_effect = function
  | Directory_unchanged -> Publication_effect_absent
  | (Directory_created_validated | Directory_created_requested_mode) ->
    Publication_effect_observed
  | Directory_state_unknown -> Publication_effect_indeterminate
;;

let publication_effect_observation_of_created_parents created_parents =
  List.fold_left
    (fun observation commit ->
       join_publication_effect_observation
         observation
         (publication_effect_observation_of_directory_target_effect
            commit.target_effect))
    Publication_effect_absent
    created_parents
;;

let publication_execution_of_error_effect ~primary ~created_parents =
  join_publication_effect_observation
    primary
    (publication_effect_observation_of_created_parents created_parents)
  |> publication_execution_of_effect_observation
;;

let content_write_observation = function
  | Ok () ->
    { execution = Publication_write_completed
    ; publication_result = `Assoc [ "outcome", `String "success" ]
    }
  | Error (Content_write_capability { error; created_parents }) ->
    { execution =
        publication_execution_of_error_effect
          ~primary:
            (publication_effect_observation_of_target_effect error.target_effect)
          ~created_parents
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_target_effect"
            , `String
                (Fs_compat.capability_write_target_effect_to_string
                   error.target_effect) )
          ; ( "filesystem_created_parent_effects"
            , created_parent_effect_observations_json created_parents )
          ]
    }
  | Error (Content_write_directory { failed_commit; created_parents }) ->
    { execution =
        publication_execution_of_error_effect
          ~primary:
            (publication_effect_observation_of_directory_target_effect
               failed_commit.target_effect)
          ~created_parents
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_directory_target_effect"
            , `String
                (created_directory_target_effect_to_string
                   failed_commit.target_effect) )
          ; ( "filesystem_created_parent_effects"
            , created_parent_effect_observations_json created_parents )
          ]
    }
  | Error (Content_write_append outcome) ->
    let target_effect = append_target_effect outcome in
    let execution =
      match target_effect with
      | Append_target_unchanged -> Publication_write_not_executed
      | ( Append_target_extended_complete
        | Append_target_extended_partial
        | Append_target_extended_detached ) ->
        Publication_write_effect_observed
      | Append_target_state_unknown -> Publication_write_indeterminate
    in
    { execution
    ; publication_result =
        `Assoc
          [ "outcome", `String "failure"
          ; "failure_class", `String "runtime_failure"
          ; ( "filesystem_append_target_effect"
            , `String (append_target_effect_to_string target_effect) )
          ]
    }
;;
