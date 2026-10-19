(** Descriptor-aware execution of a validated Keeper tool-composition plan.

    The ordinary schedule follows explicit dependency layers and descriptor
    [Serial], [Concurrent], and [Terminal] declarations. Exact filesystem-owned
    Inline file preparations additionally supply resource ordering at runtime;
    display groups and tool names never do. Every node result retains the
    canonical {!Tool_result.disposition}. *)

type scheduled_node = private
  { node : Keeper_tool_plan.node
  ; contract : Keeper_tool_plan.contract
  ; schedule : Agent_core.Tool_contract.schedule
  }

type batch = private
  | Serial_batch of scheduled_node
  | Concurrent_batch of scheduled_node list

(** Exact immutable schedule derived from dependency edges and descriptor
    execution declarations. A private index local to the call resolves original
    plan ordinals; table ordering never determines node or batch order. *)
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
  ; physical_execution_id : Ids.Execution_id.t option
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
(** [execution_id] is the stable logical occurrence, including rechecks.
    [physical_execution_id] comes from a fresh dispatched invocation. [None]
    means this settlement supplies no physical dispatch identity, including
    retained completions and compiled pure operands; observers must not mint it. *)

type dispatch_result

type admission_rejection =
  { detail : string
  ; data : Yojson.Safe.t
  }
(** A runtime admission failure before the ordinary handler is called. *)

(** Construct a low-level dispatch settlement. Callers that own more precise
    producer evidence must supply it; absent failure evidence is conservatively
    treated as an unknown effect outcome. Supply [physical_execution_id] only
    from the invocation actually dispatched, never from its logical node id. *)
val dispatch_result
  :  ?physical_execution_id:Ids.Execution_id.t
  -> ?failure_effect_disposition:Tool_result.failure_effect_disposition
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
  ; additional_causes : cause list
  ; effect_disposition : Tool_result.failure_effect_disposition
  }

val failure_causes : failure -> cause list
(** All actual causes in planned order, with [cause] as the first display
    cause and [additional_causes] as its disjoint tail. Completion decisions
    must retain sibling journal/observation failures even when an earlier
    node is merely waiting. *)

type dispatch =
  ?launch_replay:Keeper_tool_execution_journal.recheck_launch
  -> tool_use_id:string
  -> node:Keeper_tool_plan.node
  -> descriptor:Keeper_tool_descriptor.t
  -> schedule:Agent_core.Tool_contract.schedule
  -> input:Yojson.Safe.t
  -> unit
  -> dispatch_result
(** [launch_replay] accompanies the replayed dispatch of an owned launch leaf:
    the original occurrence identity plus the invocation identity recorded on
    the durable journal occurrence. Adapters that run the real Keeper handler
    use it to re-derive exactly the recorded invocation identity, so the
    owned-job start is idempotent across interruption. Dispatchers that never
    admit launch leaves may ignore it. *)

type compiled_dispatch =
  attempt:Keeper_tool_execution_journal.attempt ->
  target:Keeper_tool_plan.execution_target ->
  tool_use_id:string -> node:Keeper_tool_plan.node ->
  schedule:Agent_core.Tool_contract.schedule -> input:Yojson.Safe.t -> dispatch_result
(** A native child producer receives the actual journal attempt, after input
    validation and before effects. Missing parent occurrence or producer
    authority is refused before dispatch. Ordinary [dispatch] is never used
    as a fallback for a compiled child, regardless of its tool name. *)

(** Execute a validated plan as a dynamic ready wave to completion. Before any
    node runs, every node input that reads no producer output is validated
    ({!Keeper_tool_plan.prepare_inputs}); a rejection there ends the plan with
    [Plan_execution_failed], no settled node and [Proven_pre_effect]. Inputs
    that read a producer output are validated when their node runs. Private
    immutable lookup indexes refer to this execution's original schedules and
    outcome/preparation promise pairs. They never share cells across executions
    or replace plan-order iteration, settlement or resource ownership. Each node
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
    ends this worker attempt. A prepared run can later recheck a producer-owned
    [keeper_job_result] wait for that same job; other deferrals reject replay.
    A journaled owned launch leaf must be able to name its exact invocation
    identity through [launch_invocation_of] (trace_id, turn_ref, and the
    executor-minted non-empty tool_use_id): the durable attempt records it,
    and an interrupted launch replays with it later. Without a complete
    identity the executor refuses the launch dispatch before any durable
    attempt, instead of starting a job interruption could not re-prove.
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
  -> ?launch_invocation_of:(unit -> Keeper_tool_execution_journal.launch_invocation option)
  -> ?admit_node:(node:Keeper_tool_plan.node -> (unit, admission_rejection) result)
  -> ?dispatch_compiled:compiled_dispatch
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
    unchanged to each leaf; absence remains unavailable source context. A
    replayed launch leaf is the one exception: its dispatch re-derives the
    invocation identity recorded on the durable journal occurrence, never the
    resuming turn's ambient context, so the owned-job invocation binding
    returns the same job. [prepared_files] binds an exact instantiated Inline
    plan to its original node inputs and opaque directory capabilities. A
    mismatched node/input is refused before the handler; it never falls back
    under a claim for different resources. Its consumer retains authorization.
    Exact prepared leaves can overlap when their producer-owned resources do
    not conflict. Conflicting leaves follow dependency-layer order, standing
    down after a failed predecessor; explicit plan dependencies still apply.
    Their original resource predecessor lists are indexed once per execution.
    Static prepared waves partition the original node lists while checking
    membership in an immutable pending-ID set local to each dependency layer;
    index/set order never selects nodes, predecessors, batches or failures.
    The resource producer returns the immutable dependency layers already used
    to derive those predecessors, and scheduling shares that original value.
    [ready_files] additionally binds producer resources after upstream outputs
    validate the actual input. Nodes publish binding before waiting for earlier
    bindings in topological order. The original Ready producer retains its
    immutable dependency layers; after checking physical plan identity, the
    executor reuses them for scheduling and stable ready binding order. Without
    file preparation, the executor constructs its own dependency layers. The value
    retains the original immutable plan nodes and their templates; it adds no
    run-input, binding, resource, settlement or execution-permission fields.
    Ready layers directly retain their
    concurrent static grouping without synthetic empty resource-edge rows or
    pending-node scans. Actual binding conflicts, exclusive execution and
    settlement ordering remain in the Ready runner. Descriptor-only and exact
    prepared-file schedules retain their own ordering rules.
    An execution-local index points into
    that same immutable order; earlier bindings are visited directly without
    reconstructing each node's predecessor list. Every earlier binding is still
    awaited and classified in topological order. Earlier opaque ordinary operations settle
    before a later file mutation captures its physical bindings. Real file
    conflicts and original Serial-to-Serial chains require success; ordering
    barriers alone do not propagate failure under Continue_independent.
    Fail_fast still stops at a failed observed barrier. Ordinary Concurrent
    leaves retain their sharing with other concurrent leaves and prepared reads.
    Pure child argument validation has no file effect. Unsupported preparation
    uses the ordinary handler alone, ordered against all earlier file effects.
    The call-owned switch releases every opened capability on cancellation.
    Each prepared leaf captures immutable Gate evidence before its handler runs. *)
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
  -> ?prepared_files:Keeper_prepared_inline_files.t
  -> ?ready_files:Keeper_prepared_inline_files.Ready.t
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
  -> ?dispatch_compiled:compiled_dispatch
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
    -> ?prepared_files:Keeper_prepared_inline_files.t
    -> ?ready_files:Keeper_prepared_inline_files.Ready.t
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
    -> ?dispatch_compiled:compiled_dispatch
    -> ?journal:Keeper_tool_execution_journal.worker
    -> ?observe_node_result:(node_result -> (unit, string) result)
    -> unit
    -> (node_result list, failure) result
end
(** Explicit compatibility adapter for tests without an enclosing Keeper turn. *)
