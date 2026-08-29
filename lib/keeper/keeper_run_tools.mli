(* keeper_run_tools — Step 7 of run_turn: agent setup, tools, progressive
   disclosure, hooks assembly, context reducer.

   Extracted from keeper_agent_run.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_agent_tool_surface
open Keeper_agent_result
open Keeper_agent_error
open Keeper_agent_prompt_metrics

(** Mutable accumulator for AGENT_CORE hook callbacks.

    AGENT_CORE hooks (before_turn, on_tool_executed) cannot return values, so
    they write into this single mutable record during Agent.run execution.
    After execution completes, {!freeze} produces an immutable snapshot.
    Concurrent tool completions serialize the whole [on_tool_executed]
    observation transaction per run; observers must therefore remain bounded
    and must not perform open-ended I/O while holding that boundary. The
    observer body remains cancellable; only releasing the per-run mutex is an
    exception-safe, non-suspending finalizer. *)
type hook_accumulator =
  { mutable meta : Keeper_meta_contract.keeper_meta
  ; mutable tool_calls : tool_call_detail list
  ; mutable current_turn : int
  ; mutable tool_surface : tool_surface_metrics
  ; mutable requested_tool_names : string list
  ; mutable receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; mutable receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  ; mutable prompt_blocks : Turn_record.prompt_block list
  ; mutable extra_system_context_digest : string option
  ; mutable extra_system_context_size : int option
  ; mutable assistant_turn_texts : string list
    (** One entry per completed provider turn, newest first: the turn's [Text]
        blocks concatenated in emission order, "" when the turn emitted none. *)
  }

(** Immutable snapshot of hook outputs after AGENT_CORE execution completes. *)
type hook_outputs =
  { out_meta : Keeper_meta_contract.keeper_meta
  ; out_tool_calls : tool_call_detail list
  ; out_tool_surface : tool_surface_metrics
  ; out_requested_tool_names : string list
  ; out_receipt_completion_contract_result :
      Keeper_execution_receipt.completion_contract_result
  ; out_receipt_actionable_signal :
      Keeper_contract_classifier.actionable_signal option
  }

val freeze : hook_accumulator -> hook_outputs

(** Agent setup produced by Step 7.

    Hook mutations flow through {!acc}, receipt refs are kept for
    facade post-processing writes, and [agent_ref] is created locally
    at the AGENT_CORE call site. *)
type agent_setup =
  { tools : Agent_core.Tool.t list
    (** Every tool this turn can run. The official-client lanes take it
        whole; see {!Keeper_tools_agent_core.tool_bundle}. *)
  ; always_loaded : Agent_core.Tool.t list
  ; deferrable : (Agent_core.Types.tool_schema * Agent_core.Tool.t) list
    (** Carried through from the bundle so the Agent Core lane can send an
        index in place of these schemas. *)
  ; cleanup : unit -> unit
  ; terminal_effect_state : unit -> Keeper_tools_agent_core.terminal_effect_state
  ; user_message : string
  ; hooks : Agent_core.Hooks.hooks
  ; on_runtime_attempt : Keeper_turn_driver.runtime_attempt -> unit
  ; model_input_projection : Agent_core.Agent.model_input_projection
  ; stage_skill_delivery_on_wire :
      runtime_id:string -> agent_core_turn:int -> Agent_core.Types.message list -> unit
  ; observe_official_client_result_handoff :
      runtime_id:string ->
      invocation:Agent_core.Tool_contract.Invocation.t ->
      content:string ->
      unit
  ; observe_official_client_native_action :
      runtime_id:string -> official_turn:int ->
      identity:Runtime_native_tools.action_identity -> tool_name:string -> unit
  ; gate_replay_evidence : Keeper_gate_replay.model_evidence option
  ; acc : hook_accumulator
  ; all_tool_names : string list
  ; skill_projection_diagnostics : Keeper_skill_catalog.projection_diagnostic list
  ; final_agent_core_turn_ordinal_ref : int option ref
  ; receipt_turn_count_ref : int option ref
  ; receipt_model_used_ref : string option ref
  ; receipt_stop_reason_ref : Runtime_agent.stop_reason option ref
  ; receipt_runtime_observation_ref : Runtime_observation.runtime_observation option ref
  ; receipt_lane_attempt_index_ref : int ref
  ; receipt_response_text_present_ref : bool ref
  }

val prepare_agent_setup
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:
       Keeper_publication_recovery_availability.turn_context
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> ctx_work:working_context
  -> session:Keeper_types.session_context
  -> base_system_prompt:string
  -> turn_system_prompt:string
  -> user_message:string
  -> dynamic_context:string
  -> history_messages:Agent_core.Types.message list
  -> shared_context:Agent_core.Context.t
  -> context_injector:Agent_core.Hooks.context_injector
  -> start_turn_count:int
  -> keeper_turn_id:int
  -> turn_kind:Turn_record.turn_kind
  -> runtime_id:string
  -> is_retry:bool
  -> config_root:string
  -> runtime_config_path:string option
  -> skill_snapshot:Skill_catalog_snapshot.t
  -> skill_names:string list option
       (** Profile-only exact Skill name selection. *)
  -> task_skill_selection:
       (Keeper_task_skill_turn.t, Keeper_task_skill_turn.error) result
       (** Frozen current+held exact selection captured beside the prompt.
           Setup must not reread mutable Workspace task state. *)
  -> trajectory_acc:Trajectory.accumulator option
  -> ?runtime_manifest_context:Keeper_runtime_manifest.turn_context
  -> ?runtime_manifest_append:(Keeper_runtime_manifest.t -> unit)
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?on_tool_stream_observation:
       (Keeper_hooks_agent_core.tool_stream_observation -> unit)
  -> ?on_tool_result_ready:(tool_call_id:string -> turn:int -> planned_index:int -> execution_id:Ids.Execution_id.t -> unit)
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?composition_plan_index:Keeper_tool_composition_plan_index.t
  -> unit
  -> (agent_setup, Agent_core.Error.t) result
