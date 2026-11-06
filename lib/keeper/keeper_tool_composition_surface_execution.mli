(** The steps around one execution of a composition plan.

    [project_execution_result] projects an execution against the exports of
    its plan and attaches the artifact manifest.
    [record_skill_composition_evidence] saves the latest evidence of a Skill
    composition and reports a failure to publish it. [async_parent_invocation]
    names the parent invocation of an asynchronous request.
    [keeper_turn_id_of], [source_observation_of_context] and
    [original_source_context] read the turn context of a run, and
    [original_source_context] rebuilds it for a resumed run.
    [execute_keeper_plan] picks the plan executor for a capability authority.
    [isolate_gate_context] forks the gate causal context and
    [with_ready_inline_files] runs a function once the inline files of the plan
    are ready.
    [Keeper_tool_composition_surface] includes this module. *)
val project_execution_result :
  base_path:string ->
  plan:Keeper_tool_plan.t ->
  execution:(Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result ->
  Tool_result.result ->
  (Tool_result.result, Tool_bridge.externalization_error) result

val record_skill_composition_evidence :
  on_publication_failure:(string -> 'a) ->
  config:Workspace_utils_backend_setup.config ->
  reference:Skill_reference.t ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  request_id:string option ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  meta:Keeper_meta_contract.keeper_meta ->
  composition_tool:string ->
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  execution:(Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result ->
  result:Tool_result.result -> unit

val async_parent_invocation :
  request_id:string ->
  Agent_core_base.Tool_contract.Invocation.t ->
  Agent_core_base.Tool_contract.Invocation.t

val keeper_turn_id_of :
  Keeper_tool_call_log_context.turn_context option -> unit -> int option

val source_observation_of_context :
  Keeper_tool_call_log_context.turn_context option ->
  Keeper_tool_execution_journal.source_observation option

val original_source_context :
  source:Keeper_tool_execution_journal.source ->
  observation:Keeper_tool_execution_journal.source_observation option ->
  Keeper_tool_call_log_context.turn_context option ->
  Keeper_tool_call_log_context.turn_context option

val execute_keeper_plan :
  capability_authority:Keeper_tool_runtime.capability_authority ->
  plan:Keeper_tool_plan.t ->
  run_id:Keeper_tool_plan.Run_id.t ->
  ?composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  keeper_turn_id:(unit -> int option) ->
  ?source_context:Keeper_tool_call_log_context.turn_context ->
  ?prepared_files:Keeper_prepared_inline_files.t ->
  ?ready_files:Keeper_prepared_inline_files.Ready.t ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate_types.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  ?record_gate_result:(operation:string ->
                       input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option ->
                 unit) ->
  ?on_deferred:(unit -> unit) ->
  ?on_external_effect_deferred:(approval_id:string option -> unit) ->
  ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit) ->
  ?admit_node:(node:Keeper_tool_plan.node -> (unit, Keeper_tool_plan_executor.admission_rejection) result) ->
  ?dispatch_compiled:Keeper_tool_plan_executor.compiled_dispatch ->
  ?journal:Keeper_tool_execution_journal.worker ->
  ?observe_node_result:(Keeper_tool_plan_executor.node_result -> (unit, string) result) ->
  unit -> (Keeper_tool_plan_executor.node_result list, Keeper_tool_plan_executor.failure) result

val isolate_gate_context :
  gate_causal_context:Keeper_gate_causal_context.t option ->
  gate_context:(unit -> Keeper_gate_types.causal_context) option ->
  record_gate_result:(operation:string ->
                      input:Yojson.Safe.t -> Tool_result.result -> unit)
                     option ->
  (unit -> Keeper_gate_types.causal_context) option *
  (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  option

val with_ready_inline_files :
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  source:Keeper_tool_call_log_context.turn_context option ->
  plan:Keeper_tool_plan.t ->
  prepared_files:'a option ->
  gate_causal_context:Keeper_gate_causal_context.t option ->
  gate_context:(unit -> Keeper_gate_types.causal_context) option ->
  record_gate_result:(operation:string ->
                      input:Yojson.Safe.t -> Tool_result.result -> unit)
                     option ->
  (Keeper_prepared_inline_files.Ready.t option ->
   (unit -> Keeper_gate_types.causal_context) option ->
   (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
   option -> 'b) ->
  'b
