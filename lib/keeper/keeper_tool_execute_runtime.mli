(* Keeper_tool_execute_runtime — typed Shell IR execution pipeline.

   Private sub-module included by [Keeper_tool_command_runtime]. Only exposes what the
   facade needs. *)

val handle_tool_execute :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  unit ->
  string

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
  val path_probe_json : cwd:string -> string -> Yojson.Safe.t
  val repo_root_public_prefix_from_cwd : string -> string option
  val repo_cwd_relative_rewrite : cwd:string -> string -> string option
  val typed_execute_response_cwd_json :
    turn_sandbox_factory:Keeper_sandbox_factory.t option ->
    cwd:string ->
    sandbox_extra_fields:(string * Yojson.Safe.t) list ->
    Yojson.Safe.t
  val dispatch_error_deterministic_retry_fields :
    Keeper_tool_execute_shell_ir.dispatch_error -> (string * Yojson.Safe.t) list
end
