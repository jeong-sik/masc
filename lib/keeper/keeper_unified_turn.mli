(** MASC orchestration of a Keeper turn.

    Observes current state, prepares the turn prompt and calls
    [Keeper_agent_run.run_turn] through [Keeper_unified_turn_execution].
    [Keeper_turn_driver] dispatches each runtime attempt to AGENT_CORE or an
    official client according to [Runtime_execution.t].

    Error classification predicates are in [Keeper_error_classify]. *)

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary = Keeper_turn_runtime_budget_event_bus.turn_event_bus_summary =
  { correlation_id : string option
  ; run_id : string option
  ; caused_by : string option
  ; event_count : int
  ; payload_kinds : string list
  }

(** Turn-local tool-event pairing state used to detect event-bus integrity
    failures. Exposed for targeted tests. *)
type turn_tool_event_tracker

val record_turn_tool_events
  :  keeper_name:string
  -> turn_tool_event_tracker
  -> Agent_core.Event_bus.event list
  -> turn_tool_event_tracker

val turn_tool_event_integrity_error
  :  turn_tool_event_tracker
  -> Agent_core.Error.t option

(** Project the initial keeper turn context budget from the routed runtime's
    prevalidated resolution, so lifecycle context math matches the provider
    that will receive the first request. Exposed for regression tests. *)
val resolved_max_context_for_turn
  :  meta:Keeper_meta_contract.keeper_meta
  -> Keeper_context_runtime.max_context_resolution
  -> int

(** Record the streaming-cancel observation shared by the Eio.Cancel handler.
    Exposed so tests can pin the supervisor [fiber_stop] branch without forcing
    a live provider cancellation. *)
val record_streaming_cancelled_observation
  :  config:Workspace.config
  -> run_meta:Keeper_meta_contract.keeper_meta
  -> runtime_id:string
  -> keeper_turn_id:int
  -> unit
  -> unit

type source_disposition = Follow_failure_route
(** Every failed turn follows its typed retry/rotate/escalate route — provider
    capacity failures and an incomplete tool transcript alike. #26545 bounds
    conversation history; whole-request provider fit is tracked in #26551. *)

type turn_failure =
  { error : Agent_core.Error.t
  ; runtime_id : string
  ; route : Keeper_runtime_failure_route.route
  ; source_disposition : source_disposition
  ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
  }
(** Exact execution identity and typed disposition route for a failed turn.
    The heartbeat queue transitions from this value; it must not reconstruct a
    possibly rotated runtime from Keeper meta. *)

type turn_success =
  | Turn_completed of { meta : Keeper_meta_contract.keeper_meta }
  | Turn_checkpointed of
      { meta : Keeper_meta_contract.keeper_meta
      ; followup : Keeper_agent_result.checkpoint_followup
      }
      (** A newer durable stimulus arrived; the turn yielded so the next
          turn carries it. *)
  | Turn_input_required of Keeper_meta_contract.keeper_meta
  | Turn_cancelled of Keeper_meta_contract.keeper_meta
  | Turn_skipped of Keeper_meta_contract.keeper_meta
  | Turn_rested of
      { meta : Keeper_meta_contract.keeper_meta
      ; rest : Keeper_turn_driver.provider_rest
      ; deferred_runtime_lane : Keeper_turn_driver.deferred_runtime_lane option
      }
      (** The provider refused the request for its own quota and stated when
          it resets ({!Keeper_turn_driver.provider_rest_of_failure}). The
          Keeper rests until [rest.release_at]: the turn-failure streak, the
          registry failure reason and fleet health are left as they were.
          [deferred_runtime_lane] is the suffix the walk left, kept for the
          dispatch after the rest. *)
(** Typed non-error result of the unified turn boundary. Only
    [Turn_completed] proves that the requested action path finished.
    [Turn_checkpointed] and [Turn_input_required] are healthy runtime exits.
    [Turn_skipped] is a turn that did no work in a non-executable phase.
    Its source stays pending. So does a [Turn_rested] turn's.
    The checkpoint reason lets the heartbeat retire an admitted attention
    batch when a newer durable source caused the yield or the typed
    repeated-assistant loop guard durably preserved the already-projected
    attention; other checkpoints preserve it for continuation. Supervisor cancellation
    and a non-executable phase remain distinct so a durable source cannot be
    acknowledged as completed work. *)

val continuation_channel_of_wake :
  Keeper_registry.wake_reason -> Keeper_continuation_channel.t option
(** The channel a turn woken by [wake] continues on: a single payload's
    routable channel, or for a batch (RFC-0377) the last member's channel when
    every member has a routable channel and all are the same conversation
    ([Keeper_continuation_channel.same_conversation]). Intake orders the wake
    by the queue's urgency-stable order, not arrival, so "last" is not
    "latest"; the members agree on the conversation, so the choice decides
    only which member's per-message stamps a reply inherits. The result feeds
    [Keeper_surface_post] defaults (an omitted [channel_id], Slack
    [thread_ts]) exactly as a single-payload wake's channel does. [None] for
    an empty wake, a proactive tick, a chat request, an unroutable payload, a
    batch with a member lacking a routable channel, or a batch spanning
    conversations. *)

val run_keeper_cycle
  :  before_dispatch_authority:(unit -> (unit, string) result)
  -> execution_path:Keeper_unified_metrics_decision.execution_path
  -> ?deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane
  -> ?on_deferred_runtime_consumed:(unit -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery_provider:
       Keeper_publication_recovery_availability.provider
  -> observation:Keeper_world_observation.world_observation
  -> turn_input:Keeper_heartbeat_source_batch.turn_input
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> ?shared_context:Agent_core.Context.t
  -> ?event_bus:Agent_core.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> unit
  -> (turn_success, turn_failure) result

(** Run a unified keeper turn.

    1. Builds unified prompt from meta + observation
    2. Calls [Keeper_agent_run.run_turn] with keeper tools and hooks
    3. Observes tool history from result to update metrics
    4. Returns updated keeper_meta

    @param config Workspace configuration
    @param execution_path Required provenance supplied by the admitting lane;
    adding a caller cannot inherit an autonomous default.
    @param meta Current keeper metadata
    @param observation World state snapshot
    @param wake What triggered this turn (#16, 38-bug campaign PR-5):
    reactive stimulus batch or the proactive cadence tick. Installed on
    [current_turn_observation] via [Keeper_registry.mark_turn_started] so
    the composite observer / dashboard can surface it. Distinct from
    [turn_decision] below, which carries the scheduler verdict into the
    prompt text and owns the execution channel rather than the registry
    observation.
    @param turn_decision The scheduler's cycle decision that fired this turn
    (RFC-0315). Its [channel] drives execution and it is threaded into
    [Keeper_unified_prompt.build_prompt] so the prompt renders the same
    decision without a context-blind recompute. *)
