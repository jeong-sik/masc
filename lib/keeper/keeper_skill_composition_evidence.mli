(** Durable latest composition evidence, partitioned by exact immutable Skill
    reference. The producer writes the typed executor settlement directly;
    readers never scan the fleet tool-call log. *)

type t

type error =
  | Invalid_record of string
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Directory_prepare_failed of Keeper_fs_durable_directory.failure
  | Lock_failed of File_lock_eio.durable_lock_error
  | Write_failed of Keeper_fs.durable_write_error

type save_outcome =
  | Saved
  | Saved_with_lock_release_error of File_lock_eio.durable_lock_error

val make :
  reference:Skill_reference.t ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core.Tool_contract.Invocation.t ->
  request_id:string option ->
  keeper_name:string ->
  composition_tool:string ->
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  result:Tool_result.result ->
  executor_settlements:Yojson.Safe.t list ->
  (t, error) result

val save_latest : Workspace.config -> t -> (save_outcome, error) result
val load_latest : Workspace.config -> Skill_reference.t -> (t option, error) result
val reference : t -> Skill_reference.t
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, error) result
val error_to_string : error -> string
