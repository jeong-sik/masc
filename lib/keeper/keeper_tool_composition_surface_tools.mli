(** The tools of a Keeper's composition surface.

    [make_tools_with_authority] builds the tool of every Skill composition the
    Keeper carries, and the Skill reader when the Keeper carries instruction
    Skills. A frozen turn surface also gets the transient prepare and run
    tools. The status and cancel tools are added when the surface can mint a
    request id: on a frozen turn surface, or when a carried composition is
    asynchronous. Each tool comes with its declared loading and model
    projection.
    [Keeper_tool_composition_surface] includes this module. *)
open Keeper_tool_composition_surface_schema

val make_tools_with_authority :
  ?instruction_skills:instruction_skill
                      list ->
  ?skill_compositions:composition_skill
                      list ->
  ?composition_plan_index:Keeper_tool_composition_plan_index.t ->
  ?record_instruction_activation:(invocation:Agent_core_base.Tool_contract.Invocation.t ->
                                  content:Keeper_skill_activation_recorder.instruction_content ->
                                  Skill_reference.t ->
                                  (Keeper_skill_activation_ledger.record_outcome,
                                   Keeper_skill_activation_recorder.error)
                                  result) ->
  ?record_composition_activation:(invocation:Agent_core_base.Tool_contract.Invocation.t ->
                                  tool_name:string ->
                                  reference:Skill_reference.t ->
                                  (Keeper_skill_activation_ledger.record_outcome,
                                   Keeper_skill_activation_recorder.error)
                                  result) ->
  ?record_nested_composition_activation:Keeper_composition_nested_run.record_activation ->
  ?nested_activation_context:Keeper_skill_activation_recorder.t ->
  ?result_delivery:Keeper_composition_result_delivery.t ->
  ?on_inline_receipt_committed:(keeper_name:string ->
                               turn_context:Keeper_tool_call_log_context.turn_context ->
                               Ids.Execution_id.t -> unit) ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  capability_authority:Keeper_tool_runtime.capability_authority ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  ?turn_sandbox_factory:Keeper_sandbox_factory.t ->
  ?turn_ctx_cell:Keeper_tool_call_log_context.cell ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate_types.causal_context) ->
  ?gate_causal_context:Keeper_gate_causal_context.t ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  ?record_gate_result:(operation:string ->
                       input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?on_completed:(composition_tool:string ->
                 Keeper_tool_execution.terminal_effect_receipt option ->
                 unit) ->
  ?on_deferred:(unit -> unit) ->
  ?on_external_effect_deferred:(approval_id:string option -> unit) ->
  ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit) ->
  ?on_externalization_error:(Tool_bridge.externalization_error -> unit) ->
  descriptors:Keeper_tool_descriptor.t list ->
  unit ->
  ((Agent_core_base.Tool.t * Tool_definition_toml.loading *
    Tool_output.model_projection) list, Tool_bridge.schema_error) result
