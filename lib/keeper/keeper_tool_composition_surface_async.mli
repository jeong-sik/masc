(** The asynchronous run of a composition: its worker and its submission.

    [async_worker_result] is the body of the background worker of an accepted
    request. It restores the turn context of the original run, checks the
    admissions of the original children, dispatches the nodes of the plan and
    returns the worker outcome. [async_submission_result] hands a plan to the
    broker as a background worker and returns the tool result that carries the
    request id. [named_async_submission_result] does the same for a named
    Skill composition.
    [Keeper_tool_composition_surface] includes this module. *)
open Keeper_tool_composition_surface_schema
open Keeper_tool_composition_surface_outcome

val async_worker_result :
  composition_execution:Keeper_tool_composition_catalog.execution_mode ->
  tool_kind:Keeper_tool_descriptor.tool_kind ->
  ?skill_reference:Skill_reference.t ->
  ?nested_calls:Keeper_composition_nested.call list ->
  ?nested_activation:Keeper_skill_activation_recorder.bound_context ->
  ?continuation:Keeper_tool_execution_journal.continuation ->
  ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
  ?after_child_submission:(Tool_result.result -> unit) ->
  ?before_child_dispatch:(unit -> unit) ->
  ?keeper_turn_id:(unit -> int option) ->
  ?before_plan_execution:(unit -> unit) ->
  ?after_node_observation:(Keeper_tool_plan_executor.node_result -> 'a) ->
  ?before_child_result_publication:(unit -> unit) ->
  ?before_child_submission_publication:(unit -> unit) ->
  plan:Keeper_tool_plan.t ->
  ?journal:Keeper_tool_execution_journal.worker ->
  tool_name:string ->
  request_id:string ->
  composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  source_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  request_sw:Eio.Switch.t ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  capability_authority:Keeper_tool_runtime.capability_authority ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  turn_context:Keeper_tool_call_log_context.turn_context option ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  unit -> Keeper_msg_async.worker_outcome

val async_submission_result :
  ?skill_reference:Skill_reference.t ->
  ?nested_calls:Keeper_composition_nested.call list ->
  ?nested_activation:Keeper_skill_activation_recorder.bound_context ->
  ?draft_reference:Tool_output.artifact_ref ->
  ?run_reference:Tool_output.artifact_ref ->
  ?composition_run_id:Keeper_tool_plan.Composition_run_id.t ->
  ?journal:Keeper_tool_execution_journal.t ->
  ?continuation:Keeper_tool_execution_journal.continuation ->
  ?on_recovery_held:(request_id:string -> reason:string -> unit) ->
  ?refusal:continuation_refusal ->
  ?before_submit:(unit -> (unit, Tool_result.result) result) ->
  ?observe_submission:((Keeper_msg_async.submit_outcome,
                        Keeper_msg_async_types.submit_error)
                       result -> (unit, string) result) ->
  ?on_producer_accepted:(string -> (unit, string) result) ->
  ?observe_settlement:(Keeper_msg_async.worker_settlement -> unit) ->
  plan:Keeper_tool_plan.t ->
  tool_name:string ->
  tool_kind:Keeper_tool_descriptor.tool_kind ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  capability_authority:Keeper_tool_runtime.capability_authority ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  turn_context:Keeper_tool_call_log_context.turn_context option ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  unit -> Tool_result.result

val named_async_submission_result :
  skill_reference:Skill_reference.t ->
  plan:Keeper_tool_plan.t ->
  tool_name:string ->
  tool_kind:Keeper_tool_descriptor.tool_kind ->
  parent_invocation:Agent_core_base.Tool_contract.Invocation.t ->
  config:Workspace_utils_backend_setup.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  capability_authority:Keeper_tool_runtime.capability_authority ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  ctx_snapshot:Keeper_types.working_context ->
  turn_context:Keeper_tool_call_log_context.turn_context option ->
  admission:named_admission ->
  ?on_child_accepted:(unit -> unit) ->
  ?before_result_publication:(unit -> unit) ->
  ?clock:float Eio.Time.clock_ty Eio.Time.clock_base ->
  unit -> Tool_result.result
