(** The reports of the directories that a write created in
    [Keeper_tool_filesystem_runtime].

    [created_directory_stage_to_string],
    [created_directory_target_effect_to_string] and
    [created_directory_failure_cause_to_string] name the parts of a
    [created_directory_commit]. [created_directory_failure_json],
    [created_directory_sync_outcome_json] and [created_directory_commit_json]
    render a failure, a sync outcome and a commit as JSON, and
    [created_parent_effects_json] renders a list of commits.
    [created_directory_sync_observation_json],
    [created_parent_effect_observation_json] and
    [created_parent_effect_observations_json] render the shorter form that
    keeps the status of each sync only.
    [capability_write_error_payload] and [created_directory_commit_payload]
    build the error payload of a failed capability write and of a failed
    directory creation, each with the directories created before it.
    [observe_created_directory_commit] logs a commit with the failure and the
    sync failures it holds; [observe_created_directory_failure_backtrace] and
    [observe_created_directory_sync_outcome] are the log lines it is built
    from.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_tool_filesystem_runtime_write_types

val created_directory_target_effect_to_string :
  created_directory_target_effect ->
  string

val created_parent_effect_observations_json :
  created_directory_commit
  list ->
  Yojson.Safe.t

val capability_write_error_payload :
  target:string ->
  created_parents:created_directory_commit
                  list ->
  Fs_compat.capability_write_error -> string

val created_directory_commit_payload :
  target:string ->
  created_parents:created_directory_commit
                  list ->
  created_directory_commit ->
  string

val observe_created_directory_commit :
  keeper_name:string ->
  target:string ->
  created_directory_commit ->
  unit
