(** Keeper_unified_turn — Single entry point for keeper turns via Agent_core.Agent.run().

    Replaces the 3-path dispatcher (social/scheduled-autonomous/autonomy) with a unified
    observe -> prompt -> Agent.run(tools, guardrails, hooks) loop.
    The model decides what to do; code only enforces safety and observes results.

    Error classification predicates are in [Keeper_error_classify].

    @since Unified Keeper Loop *)

type degraded_retry_decision =
  | No_degraded_retry
  | Degraded_retry_allowed of Keeper_error_classify.degraded_retry

val decide_degraded_retry
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> Agent_core.Error.t
  -> degraded_retry_decision

(** Summary of event-bus signals observed during a single keeper turn.
    Exposed for regression tests. *)
type turn_event_bus_summary =
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

(* runtime→Runtime 숙청: phase-buffer liveness probe 기계 재export 제거
   (단일 runtime 에서 죽은 코드였으므로 제거됨). *)

(** Typed phase-gate output for the first turn pipeline boundary.
    [run_keeper_cycle] converts this record into the manifest
    [Phase_gate_decided] row and then dispatches the matching terminal or
    runtime-routing branch. *)
type turn_plan_status =
  | Turn_plan_dispatch
  | Turn_plan_skipped
  | Turn_plan_cancelled
  | Turn_plan_error

type turn_plan =
  { turn_plan_keeper_turn_id : int
  ; turn_plan_phase : string option
  ; turn_plan_status : turn_plan_status
  ; turn_plan_executable : bool
  ; turn_plan_reason : string
  ; turn_plan_terminal_reason_code : string option
  }

val decide_turn_plan_at_phase_gate
  :  keeper_turn_id:int
  -> supervisor_stop_at_entry:bool
  -> Keeper_state_machine.phase option
  -> turn_plan


(** Resolve the next runtime to try after an auto-recoverable failure.
    Uses the current effective runtime and the default degraded rotation
    candidate, then suppresses suggestions
    that would loop back to a runtime already attempted during the current
    turn. Exposed for targeted tests. *)
val next_fail_open_runtime_for_turn
  :  base_runtime:string
  -> effective_runtime:string
  -> attempted_runtimes:string list
  -> Agent_core.Error.t
  -> Keeper_error_classify.degraded_retry option

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

type continuation_route_disposition =
  | Continuation_route_addressed
  | Continuation_route_mismatch
  | Continuation_memory_write_completed
  | Continuation_memory_retract_completed
  | Continuation_no_terminal_effect_receipt
  | Continuation_route_not_applicable
(** Producer-owned evidence available when a completed turn is compared with
    its continuation route. [Continuation_route_addressed] and
    [Continuation_route_mismatch] come from a concrete surface-post receipt;
    [Continuation_memory_write_completed] and
    [Continuation_memory_retract_completed] record the other concrete terminal
    receipts; [Continuation_no_terminal_effect_receipt] records absence without
    claiming the stimulus was unobserved; [Continuation_route_not_applicable]
    means this was not a continuation wake. Policy may map these facts to queue
    actions, but must not rename them into model intent. *)

type checkpoint_reason = Keeper_turn_checkpoint_reason.t =
  | Operation_queued
  | Durable_stimulus_arrived
  | Repeated_tool_call of
      { tool_name : string
      ; repeated_count : int
      }
  | Repeated_assistant_text of { repeated_count : int }
(** Why a healthy turn checkpointed before [Completed]. The definition lives
    in {!Keeper_turn_checkpoint_reason} so the prompt can read it without
    depending on this module; the equation keeps the constructors usable
    here. [Durable_stimulus_arrived] proves that a newer durable source
    caused the yield. The two [Repeated_*] guards carry what repeated, so the
    next turn's prompt can name it. *)

type turn_success =
  | Turn_completed of
      { meta : Keeper_meta_contract.keeper_meta
      ; continuation_route : continuation_route_disposition
      }
  | Turn_checkpointed of
      { meta : Keeper_meta_contract.keeper_meta
      ; checkpoint_reason : checkpoint_reason
      ; continuation_route : continuation_route_disposition
      }
  | Turn_input_required of Keeper_meta_contract.keeper_meta
  | Turn_cancelled of Keeper_meta_contract.keeper_meta
  | Turn_skipped of Keeper_meta_contract.keeper_meta
(** Typed non-error result of the unified turn boundary. Only
    [Turn_completed] proves that the requested action path finished.
    [Turn_checkpointed] and [Turn_input_required] are healthy runtime exits.
    The checkpoint reason lets the heartbeat retire an admitted attention
    batch when a newer durable source caused the yield or the typed
    repeated-assistant loop guard durably preserved the already-projected
    attention; other checkpoints preserve it for continuation. Supervisor cancellation
    and a non-executable phase remain distinct so a durable source cannot be
    acknowledged as completed work. *)

val hitl_replay_preemption_request
  :  resolution_deliverable:(Keeper_event_queue.hitl_resolution -> bool)
  -> now:float
  -> Keeper_event_queue.t
  -> Keeper_agent_run.autonomous_yield_request option
(** Pure post-tool boundary decision (#28809): yield the in-flight source when
    a queued [Hitl_resolved] passes [resolution_deliverable]. The runtime
    predicate accepts only an approved resolution whose one-shot grant is
    still unspent, so a resolution already threaded into the current turn
    (grant consumed at tool-bundle build) never preempts its own run. *)

val hitl_replay_yield_request
  :  base_path:string
  -> keeper_name:string
  -> (Keeper_agent_run.autonomous_yield_request option, string) result
(** [hitl_replay_preemption_request] over the keeper's durable queue snapshot
    with the runtime deliverability predicate (approval left the pending map,
    grant durably unspent). *)


val run_keeper_cycle
  :  before_dispatch_authority:(unit -> (unit, string) result)
  -> ?deferred_runtime_lane:Keeper_turn_driver.deferred_runtime_lane
  -> ?on_deferred_runtime_consumed:(unit -> unit)
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> publication_recovery_provider:
       Keeper_publication_recovery_availability.provider
  -> observation:Keeper_world_observation.world_observation
  -> wake:Keeper_registry.wake_reason
  -> turn_decision:Keeper_world_observation.keeper_cycle_decision
  -> ?previous_turn_stop:Keeper_turn_checkpoint_reason.t
  -> ?shared_context:Agent_core.Context.t
  -> ?event_bus:Agent_core.Event_bus.t
  -> ?hitl_resolution:Keeper_event_queue.hitl_resolution
  -> unit
  -> (turn_success, turn_failure) result

(** Run a unified keeper turn.

    [?previous_turn_stop] is the checkpoint reason of this keeper's last turn
    that ran in this process, when that turn did not complete. The prompt
    renders it so the model knows why it stopped; the checkpoint history
    shows the calls but not the reason the runtime ended the turn.

    1. Builds unified prompt from meta + observation
    2. Calls [Keeper_agent_run.run_turn] with keeper tools and hooks
    3. Observes tool history from result to update metrics
    4. Returns updated keeper_meta

    @param config Workspace configuration
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
