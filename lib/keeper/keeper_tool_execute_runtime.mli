(* Keeper_tool_execute_runtime — typed Shell IR execution pipeline.

   Private sub-module included by [Keeper_tool_command_runtime]. Only exposes what the
   facade needs. *)

val handle_tool_execute :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  exec_cache:Masc_exec.Exec_cache.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  string

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
  val typed_execute_response_cwd_json :
    turn_sandbox_factory:Keeper_sandbox_factory.t option ->
    cwd:string ->
    sandbox_extra_fields:(string * Yojson.Safe.t) list ->
    Yojson.Safe.t
  val execute_gate_input :
    input:Yojson.Safe.t ->
    cwd:string ->
    sandbox_profile:string ->
    sandbox_target:string ->
    Yojson.Safe.t
  val redact_execute_output :
    base_path:string ->
    keeper_name:string ->
    stdout:string ->
    stderr:string ->
    string * string * string
end
