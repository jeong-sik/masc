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
  val record_pr_action_metric :
    keeper_name:string ->
    risk_class:Masc_exec.Shell_ir_risk.risk_class ->
    status:Unix.process_status ->
    Masc_exec.Shell_ir.t ->
    unit
  val record_gh_classification_metric :
    keeper_name:string ->
    risk_class:Masc_exec.Shell_ir_risk.risk_class ->
    typed_hit:bool ->
    Masc_exec.Shell_ir.t ->
    unit
  val shell_ir_approval_overlay : unit -> Masc_exec.Approval_config.agent_overlay
  val shell_ir_approval_input :
    cmd:string ->
    cwd:string ->
    bin:string ->
    summary:string ->
    sandbox_profile:string ->
    sandbox_target:string ->
    risk_class:Masc_exec.Shell_ir_risk.risk_class ->
    typed_hit:bool ->
    ?repo_create_contract:Yojson.Safe.t ->
    unit ->
    Yojson.Safe.t
  val submit_shell_ir_approval_pending :
    base_path:string ->
    keeper_name:string ->
    ?task_id:string ->
    ?goal_ids:string list ->
    cmd:string ->
    cwd:string ->
    bin:string ->
    summary:string ->
    sandbox_profile:string ->
    sandbox_target:string ->
    risk_class:Masc_exec.Shell_ir_risk.risk_class ->
    typed_hit:bool ->
    ?repo_create_contract:Yojson.Safe.t ->
    unit ->
    string
  val redact_execute_output :
    base_path:string ->
    keeper_name:string ->
    stdout:string ->
    stderr:string ->
    string * string * string
  val dispatch_error_deterministic_retry_fields :
    Keeper_tool_execute_shell_ir.dispatch_error -> (string * Yojson.Safe.t) list
end
