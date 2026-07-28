(* Keeper_tool_execute_runtime — typed Shell IR execution pipeline.

   Private sub-module included by [Keeper_tool_command_runtime]. Only exposes what the
   facade needs. *)

val handle_tool_execute :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  string

val gate_operation : string
(** The Gate operation name this runtime submits under. Shared with the replay
    path so an approved execute is recognised rather than skipped. *)

val replay_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Recover the approved tool arguments from the stored Gate input.

    The Gate request wraps the arguments with execution context rather than
    re-encoding them, so the approved arguments are returned verbatim. The
    stored [cwd]/[sandbox_*] fields are not replayed: the handler re-derives
    them from the current turn, and a divergence fails the canonical-input
    match instead of executing somewhere the approval did not describe. *)

val handle_tool_execute_with_outcome :
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  args:Yojson.Safe.t ->
  unit ->
  Keeper_tool_execution.t

module For_testing : sig
  val elapsed_duration_ms : start_time:float -> end_time:float -> int
  val model_execute_location_fields :
    config:Workspace.config ->
    meta:Keeper_meta_contract.keeper_meta ->
    args:Yojson.Safe.t ->
    cwd:string ->
    (string * Yojson.Safe.t) list
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
