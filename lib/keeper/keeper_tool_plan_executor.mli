(** Descriptor-aware execution of a validated Keeper tool-composition plan.

    The executor schedules only explicit dependency layers. Descriptor
    [Serial], [Concurrent], and [Terminal] values determine execution batches;
    display groups and tool names never do. Every node result retains the
    canonical {!Tool_result.disposition}. *)

type scheduled_node = private
  { node : Keeper_tool_plan.node
  ; descriptor : Keeper_tool_descriptor.t
  ; schedule : Agent_core.Tool_contract.schedule
  }

type batch = private
  | Serial_batch of scheduled_node
  | Concurrent_batch of scheduled_node list

(** Exact immutable schedule derived from dependency edges and descriptor
    execution declarations. *)
val schedule : Keeper_tool_plan.t -> batch list

(** Completion declaration for the outer composite tool. Nested actions always
    continue into executor settlement; a final terminal descriptor makes the
    single outer composite invocation terminal. *)
val outer_completion : Keeper_tool_plan.t -> Agent_core.Tool_contract.completion

type node_execution_origin = Keeper_skill_composition_evidence.Node_execution_origin.t =
  | Fresh_dispatch
  | Retained_completion
  | Dispatch_refused

val node_execution_origin_to_string : node_execution_origin -> string

type node_result = private
  { node_id : Keeper_tool_plan.Node_id.t
  ; execution_id : Ids.Execution_id.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; schedule : Agent_core.Tool_contract.schedule
  ; result : Tool_result.result
  ; output_validation_error : Keeper_tool_plan.execution_error option
  ; tool_use_id : string
  ; execution_origin : node_execution_origin
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int
  ; truncated_to : int option
  }

type dispatch_result

type admission_rejection =
  { detail : string
  ; data : Yojson.Safe.t
  }
(** A runtime admission failure before the ordinary handler is called. *)

(** Construct a low-level dispatch settlement. Callers that own more precise
    producer evidence must supply it; absent failure evidence is conservatively
    treated as an unknown effect outcome. *)
val dispatch_result
  :  ?failure_effect_disposition:Tool_result.failure_effect_disposition
  -> ?deferred_kind:Keeper_tool_execution.deferred_kind
  -> ?result_bytes:int
  -> ?truncated_to:int
  -> Tool_result.result
  -> dispatch_result

type cause =
  | Run_journal_rejected of Keeper_tool_execution_journal.error
  | Plan_execution_failed of
      { node_id : Keeper_tool_plan.Node_id.t
      ; schedule : Agent_core.Tool_contract.schedule
      ; error : Keeper_tool_plan.execution_error
      }
  | Tool_did_not_complete of node_result
  | Node_observation_failed of
      { node : node_result
      ; detail : string
      }
  | Outer_completion_mismatch of
      { expected : Agent_core.Tool_contract.completion
      ; actual : Agent_core.Tool_contract.completion
      }

type failure = private
  { settled : node_result list
  ; cause : cause
  ; effect_disposition : Tool_result.failure_effect_disposition
  }

type dispatch =
  tool_use_id:string
  -> node:Keeper_tool_plan.node
  -> descriptor:Keeper_tool_descriptor.t
  -> schedule:Agent_core.Tool_contract.schedule
  -> input:Yojson.Safe.t
  -> dispatch_result

(** Execute a validated plan as a dynamic ready wave to completion. Before any
    node runs, every node input that reads no producer output is validated
    ({!Keeper_tool_plan.prepare_inputs}); a rejection there ends the plan with
    [Plan_execution_failed], no settled node and [Proven_pre_effect]. Inputs
    that read a producer output are validated when their node runs. Each node
    dispatches as soon as its dependencies have settled instead of waiting
    for a static batch barrier; serial and terminal nodes additionally run
    alone in static schedule order, and a serial or terminal node whose serial
    predecessor failed, deferred (a cause), or was skipped never dispatches a
    tool — the chain stands down under either branch failure policy, while the
    failed predecessor itself carries the plan cause through planned index
    order. In-flight nodes always settle before the lowest-planned-index cause
    is selected. Settled results are reported in canonical plan order
    (non-decreasing [planned_index]); the plan's
    {!Keeper_tool_plan.branch_failure_policy} decides what a blocked node
    stops: [Fail_fast] stops every node that has not dispatched yet, while
    [Continue_independent] only stops the failed node's descendants and lets
    independent branches settle. A [Deferred]
    or [Failed] tool result is carried unchanged in [Tool_did_not_complete];
    no text or payload inference is performed. A deferred node produces no
    composable output, so it cannot satisfy a downstream output reference and
    terminates the plan instead of being resumed as a producer.
    The executor mints one non-empty [tool_use_id] before calling [dispatch];
    the dispatch, exception settlement, durable row, and live refresh all share
    that identity. [observe_node_result], when supplied, is part of settlement: an observation
    error becomes [Node_observation_failed] after every in-flight sibling has
    settled, preserving the aggregate effect disposition.

    A supplied [journal] is the prepared run's canonical async worker binding.
    It records the exact occurrence before dispatch and commits the producer's
    typed settlement before ordinary observation. Retained completed results
    preserve their original occurrence and payload, revalidate output against
    this plan/run, and do not dispatch or repeat ordinary tool observations.
    Missing or unavailable journal authority never becomes a fresh node. *)
val execute
  :  plan:Keeper_tool_plan.t
  -> run_id:Keeper_tool_plan.Run_id.t
  -> dispatch:dispatch
  -> ?journal:Keeper_tool_execution_journal.worker
  -> ?observe_node_result:(node_result -> (unit, string) result)
  -> unit
  -> (node_result list, failure) result

(** Runtime adapter through the ordinary Keeper Agent-Core handler. This keeps
    descriptor input translation, Gate, Shell IR routing, tool-call telemetry,
    and per-action I/O previews on the same boundary as a direct Keeper call.
    [admit_node], if present, runs after dependency/input validation and before
    the handler. A rejection settles the leaf as a runtime failure with
    [Proven_pre_effect], preserving the normal branch failure policy.
    [source_context] is the original composition invocation snapshot passed
    unchanged to each leaf; absence remains unavailable source context. *)
val execute_keeper
  :  capability_surface:Keeper_capability_surface.t
  -> plan:Keeper_tool_plan.t
  -> run_id:Keeper_tool_plan.Run_id.t
  -> ?composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> parent_invocation:Agent_core.Tool_contract.Invocation.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery:Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> keeper_turn_id:(unit -> int option)
  -> ?source_context:Keeper_tool_call_log_context.turn_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option -> unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(approval_id:string option -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?admit_node:
       (node:Keeper_tool_plan.node -> (unit, admission_rejection) result)
  -> ?journal:Keeper_tool_execution_journal.worker
  -> ?observe_node_result:(node_result -> (unit, string) result)
  -> unit
  -> (node_result list, failure) result

module Compatibility : sig
  val execute_keeper
    :  plan:Keeper_tool_plan.t
    -> run_id:Keeper_tool_plan.Run_id.t
    -> ?composition_run_id:Keeper_tool_plan.Composition_run_id.t
    -> parent_invocation:Agent_core.Tool_contract.Invocation.t
    -> config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> publication_recovery:
         Keeper_publication_recovery_availability.turn_context
    -> ctx_snapshot:Keeper_types.working_context
    -> keeper_turn_id:(unit -> int option)
    -> ?source_context:Keeper_tool_call_log_context.turn_context
    -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
    -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
    -> ?continuation_channel:Keeper_continuation_channel.t
    -> ?gate_context:(unit -> Keeper_gate.causal_context)
    -> ?gate_grant:Keeper_gate.cycle_grant
    -> ?record_gate_result:
         (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
    -> ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option -> unit)
    -> ?on_deferred:(unit -> unit)
    -> ?on_external_effect_deferred:(approval_id:string option -> unit)
    -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
    -> ?admit_node:
         (node:Keeper_tool_plan.node -> (unit, admission_rejection) result)
    -> ?journal:Keeper_tool_execution_journal.worker
    -> ?observe_node_result:(node_result -> (unit, string) result)
    -> unit
    -> (node_result list, failure) result
end
(** Explicit compatibility adapter for tests without an enclosing Keeper turn. *)
