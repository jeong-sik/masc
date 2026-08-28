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

type node_result = private
  { node_id : Keeper_tool_plan.Node_id.t
  ; execution_id : Ids.Execution_id.t
  ; tool_name : string
  ; input : Yojson.Safe.t
  ; schedule : Agent_core.Tool_contract.schedule
  ; result : Tool_result.result
  ; tool_use_id : string
  ; failure_effect_disposition : Tool_result.failure_effect_disposition option
  ; deferred_kind : Keeper_tool_execution.deferred_kind option
  ; result_bytes : int
  ; truncated_to : int option
  }

type dispatch_result

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

(** Execute dependency batches to completion. Concurrent siblings are all
    settled before the lowest-planned-index cause is selected. A [Deferred]
    or [Failed] tool result is carried unchanged in [Tool_did_not_complete];
    no text or payload inference is performed. A deferred node produces no
    composable output, so it cannot satisfy a downstream output reference and
    terminates the plan instead of being resumed as a producer.
    The executor mints one non-empty [tool_use_id] before calling [dispatch];
    the dispatch, exception settlement, durable row, and live refresh all share
    that identity. [observe_node_result], when supplied, is part of settlement: an observation
    error becomes [Node_observation_failed] after every sibling in the current
    batch has settled, preserving the aggregate effect disposition. *)
val execute
  :  plan:Keeper_tool_plan.t
  -> run_id:Keeper_tool_plan.Run_id.t
  -> dispatch:dispatch
  -> ?observe_node_result:(node_result -> (unit, string) result)
  -> unit
  -> (node_result list, failure) result

(** Runtime adapter through the ordinary Keeper Agent-Core handler. This keeps
    descriptor input translation, Gate, Shell IR routing, tool-call telemetry,
    and per-action I/O previews on the same boundary as a direct Keeper call. *)
val execute_keeper
  :  plan:Keeper_tool_plan.t
  -> run_id:Keeper_tool_plan.Run_id.t
  -> ?composition_run_id:Keeper_tool_plan.Composition_run_id.t
  -> parent_invocation:Agent_core.Tool_contract.Invocation.t
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> capability_authority:Keeper_tool_runtime.capability_authority
  -> publication_recovery:Keeper_publication_recovery_availability.turn_context
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?gate_context:(unit -> Keeper_gate.causal_context)
  -> ?gate_grant:Keeper_gate.cycle_grant
  -> ?record_gate_result:
       (operation:string -> input:Yojson.Safe.t -> Tool_result.result -> unit)
  -> ?on_completed:(Keeper_tool_execution.terminal_effect_receipt option -> unit)
  -> ?on_deferred:(unit -> unit)
  -> ?on_external_effect_deferred:(unit -> unit)
  -> ?on_failed:(Keeper_tools_agent_core.terminal_effect_failure -> unit)
  -> ?observe_node_result:(node_result -> (unit, string) result)
  -> unit
  -> (node_result list, failure) result
