(** Keeper single-turn orchestration via OAS Agent.run().

    This module is intentionally a compatibility facade: public types and
    entrypoints stay here while prompt metrics, result/error helpers, and
    tool-surface policy live in focused implementation modules. *)

include module type of Keeper_agent_prompt_metrics
include module type of Keeper_agent_tool_surface
include module type of Keeper_agent_result
include module type of Keeper_agent_error

module Contract_helpers = Keeper_agent_run_contract_helpers
module Turn_helpers = Keeper_agent_run_turn_helpers

(** Outcome of building the per-turn OAS raw-trace sink
    ([.masc/keepers/<name>/raw-traces/turn-*.jsonl]). [Sink_degraded] is
    the typed health record for trace-store failures: the turn still
    dispatches (untraced, so [run_result.trace_ref]/[run_validation] stay
    [None] for that turn) — trace-store state never fails a turn
    pre-dispatch. *)
type raw_trace_sink_outcome =
  | Sink_ready of Agent_sdk.Raw_trace.t
  | Sink_degraded of Agent_sdk.Error.sdk_error

(** Typed reason and boundary for an autonomous Keeper run to release its lane
    at an OAS turn boundary. Scheduled-idle chat can yield immediately;
    reactive chat and durable backlog yield only after the current cycle has
    completed at least one provider turn, so a leased stimulus is never
    acknowledged without being observed by the model. *)
type autonomous_yield_reason =
  | Chat_waiting
  | Durable_stimulus_waiting

type autonomous_yield_boundary =
  | Yield_immediately
  | Yield_after_current_turn

type autonomous_yield_request = {
  reason : autonomous_yield_reason;
  boundary : autonomous_yield_boundary;
}

module For_testing : sig
  val sse_event_progress_kind : Agent_sdk.Types.sse_event -> string option
  val sse_event_watchdog_progress_kind :
    Agent_sdk.Types.sse_event -> string option
  val registry_progress_on_event
    :  record_turn_progress:(string -> unit)
    -> (Agent_sdk.Types.sse_event -> unit) option
    -> Agent_sdk.Types.sse_event
    -> unit
  val progress_keeper_tool_names_for_contract
    :  actual_keeper_tool_names:string list
    -> tool_calls:tool_call_detail list
    -> string list

  val normalize_response_text_for_finalization
    :  runtime_id:string
    -> initial_messages:Agent_sdk.Types.message list
    -> run_result:Runtime_agent.run_result
    -> text:string
    -> tool_names:string list
    -> unit
    -> (string, Agent_sdk.Error.sdk_error) result

  (** OAS raw-trace sink for keeper turns: a fresh per-turn file under
      [Keeper_types_support.keeper_raw_trace_dir], pruned to
      [Keeper_types_support.raw_trace_retained_turn_files]. The dispatch
      section passes it into [Keeper_turn_driver.run_named] so
      [run_result.trace_ref]/[run_validation] are populated. *)
  val keeper_raw_trace_sink
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> raw_trace_sink_outcome

  (** Dispatch adapter over {!keeper_raw_trace_sink}: [Sink_degraded]
      becomes [None] (turn runs untraced) after emitting the typed
      degrade record (warn log + [Keeper_metrics.RawTraceSinkDegraded]
      counter). Never raises; never fails the turn. *)
  val raw_trace_for_dispatch
    :  config:Workspace.config
    -> meta:Keeper_meta_contract.keeper_meta
    -> Agent_sdk.Raw_trace.t option

  val autonomous_yield_allowed_at_turn
    :  start_turn:int
    -> turn:int
    -> autonomous_yield_request
    -> bool

  val stop_reason_of_autonomous_yield
    :  turn:int
    -> autonomous_yield_request
    -> Runtime_agent.stop_reason

  val keeper_max_turns : int
  (** OAS-owned unbounded sentinel used explicitly for every Keeper run. *)
end

(** {1 Turn execution} *)

(** Run a single keeper turn.

    @param config Workspace configuration
    @param meta Keeper metadata
    @param base_dir Session base directory for checkpoints
    @param max_context Maximum context window tokens
     @param build_turn_prompt Callback: receives the base keeper system prompt
            and checkpoint message history, returns the final turn system prompt
     @param user_message The user's message to the keeper
    @param user_blocks Optional structured user-authored OAS content blocks for
           the current turn. [user_message] remains the display/history
           fallback and must not contain raw media payloads.
    @param runtime_id Typed runtime profile name for model selection
     @param world_observation Structured keeper world snapshot used by
            advisory execution-progress checks. When omitted, the progress check
            does not infer world state from prompt text.
    @param generation Current generation counter
    @param history_user_source Source label for user messages in history
    @param history_assistant_source Source label for assistant messages in history
    @param temperature Subsystem temperature fallback; a selected runtime model
           declaration takes precedence
    @param on_event Optional event callback
    @param trajectory_acc Optional trajectory accumulator for recording
    @param priority Optional priority for scheduling
    @param is_retry When [true], replays current user message without persisting
    @param shared_context Optional shared OAS context for cross-turn state
    @param event_bus Optional MASC event bus *)
val run_turn
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> profile_defaults:Keeper_types_profile.keeper_profile_defaults
  -> turn_ctx_cell:Keeper_tool_call_log.turn_ctx_cell
  -> base_dir:string
  -> max_context:int
  -> build_turn_prompt:
       (base_system_prompt:string -> messages:Agent_sdk.Types.message list -> turn_prompt)
  -> user_message:string
  -> ?user_blocks:Agent_sdk.Types.content_block list
  -> runtime_id:string
  -> ?world_observation:Keeper_world_observation.world_observation
  -> generation:int
  -> ?history_user_source:string
  -> ?history_assistant_source:string
  -> ?temperature:float
  -> ?on_event:(Agent_sdk.Types.sse_event -> unit)
  -> ?trajectory_acc:Trajectory.accumulator
  -> ?priority:Llm_provider.Request_priority.t
  -> ?degraded_retry_applied:bool
  -> ?degraded_retry_runtime:string
  -> ?fallback_reason:Keeper_error_classify.degraded_retry_reason
  -> ?runtime_rotation_attempts:Keeper_execution_receipt.runtime_rotation_attempt list
  -> ?is_retry:bool
  -> ?shared_context:Agent_sdk.Context.t
  -> ?event_bus:Agent_sdk.Event_bus.t
  -> ?trace_link:string * string
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> ?continuation_delivery_channel:Keeper_continuation_channel.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> ?autonomous_yield_requested:(unit -> autonomous_yield_request option)
       (* Autonomous-lane hook: evaluated at each OAS agent-loop turn boundary
          before the next model dispatch — never mid tool execution. A typed
          request stops the run gracefully at the boundary allowed by
          [autonomous_yield_reason], releasing the lane for queued chat or
          durable stimulus work. Only the heartbeat-scheduled path passes it; a
          chat turn never receives this hook. *)
  -> ?on_checkpoint_stage:(Agent_sdk.Agent.checkpoint_stage -> unit)
  -> unit
  -> (run_result, Agent_sdk.Error.sdk_error) result
