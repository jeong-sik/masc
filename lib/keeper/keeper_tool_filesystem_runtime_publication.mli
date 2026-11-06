(** The outcome of the publication of a write in
    [Keeper_tool_filesystem_runtime].

    [file_write_attempt_to_execution] turns a [file_write_attempt] into a tool
    outcome. For a successful write it attaches the artifact manifest to the
    result, then the file change evidence.
    [publication_recovery_unavailable_attempt] is the failed attempt for a
    publication whose recovery is unavailable.
    [content_write_observation] says how far a content write got: its
    [publication_write_execution] (completed, effect observed, not executed or
    indeterminate) and the JSON of its result. The execution comes from a
    [publication_effect_observation] of the target and of each created
    directory. [publication_effect_observation_of_target_effect],
    [publication_effect_observation_of_directory_target_effect] and
    [publication_effect_observation_of_created_parents] read it from the
    effects, [join_publication_effect_observation] keeps the stronger of two
    (observed over indeterminate over absent), and
    [publication_execution_of_effect_observation] and
    [publication_execution_of_error_effect] turn it into an execution.
    [finish_recovery_guarded_write] finishes a write that ran under a
    publication recovery lane. When the lane could not be released it returns
    the attempt that [publication_recovery_cleanup_failed_attempt] builds.
    [Keeper_tool_filesystem_runtime] includes this module. *)
open Keeper_tool_filesystem_runtime_write_types

val file_write_attempt_to_execution :
  config:Workspace_utils_backend_setup.config ->
  file_write_attempt ->
  Keeper_tool_execution.t

val publication_recovery_unavailable_attempt :
  Keeper_publication_recovery_availability.unavailable ->
  file_write_attempt

type publication_write_execution =
  | Publication_write_completed
  | Publication_write_effect_observed
  | Publication_write_not_executed
  | Publication_write_indeterminate

type publication_callback_observation =
  { execution : publication_write_execution
  ; publication_result : Yojson.Safe.t
  }

val finish_recovery_guarded_write :
  keeper_name:string ->
  target:string ->
  observe_result:('a -> publication_callback_observation) ->
  finish:('a ->
          (file_write_attempt,
           string)
          result) ->
  'a Fs_compat.Publication_recovery.lane_outcome ->
  (file_write_attempt,
   string)
  result

val content_write_observation :
  (unit,
   content_write_error)
  result -> publication_callback_observation
