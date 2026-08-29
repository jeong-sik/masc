(** MASC-owned HITL domain judgment over the opaque-runtime AGENT_CORE exact-output
    flow. MASC freezes the request and domain schema, validates the returned
    judgment, and owns approval queue durability. AGENT_CORE alone owns candidate
    admission, attempt allocation, execution, failover, receipts, and
    provenance. *)

val lane_id : string
(** The registry lane id this worker resolves. Exposed so startup validation and
    config fixtures name the lane through this module instead of repeating the
    literal, matching {!Keeper_board_attention_exact_flow.lane_id}. *)

val snapshot_topology_readiness : unit -> (unit, string) result
(** Verify only prompt availability and that the registry-owned
    [hitl_auto_judge] topology can be frozen as an AGENT_CORE exact-output snapshot.
    This is not credential, wire, or output admission. *)

exception Exact_terminalization_persistence_failed of string

type execution_boundary =
  | Executed
  | Identity_unbound_blocked
  | Exact_rejection_blocked of Keeper_approval_queue.exact_attempt_rejection

type finish_outcome =
  | Conclusive_terminalization
  | Terminalization_persistence_uncertain
  | Terminalization_identity_unbound
  | Terminalization_rejected

type spawn_outcome =
  | Worker_forked

(** Every terminal disposition of the HITL exact-output flow.

    Closed on purpose: these were 27 string literals across 37 call sites,
    so a branch added later reached the metric without the compiler asking.
    Each derivation is now an exhaustive match. *)
type flow_outcome =
  | Ok_summary
  | Ok_summary_cli
  | Source_resolved
  | Identity_unbound
  | Identity_unbound_source_changed
  | Terminal_sync_unconfirmed
  | Terminal_persistence_failure
  | Terminal_rejected
  | Provenance_mismatch
  | Domain_invalid_output
  | Attempt_replay
  | Attempt_start_failed
  | Measurement_start_failed
  | Measurement_callback_failed
  | Candidates_exhausted
  | Bind_failed
  | Release_failed
  | Execution_failed
  | Cli_slots_exhausted
  | Cli_released_without_binding
  | Cli_walk_fell_back
  | Cli_release_unconfirmed
  | Cli_bind_unconfirmed
  | Cli_bind_failed
  | Cancellation
  | Cancellation_settlement_failed
  | Crashed

val outcome_label : flow_outcome -> string
(** The metric label for an outcome. The text is the contract with anything
    reading the [HitlSummaryOutcomes] counter, so it is derived here rather
    than restated at each recording site; [test_hitl_summary_worker] pins
    every pair. *)


val spawn
  :  sw:Eio.Switch.t
  -> entry:Keeper_approval_queue_rules_types.pending_approval
  -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
  -> on_finish:(finish_outcome -> unit)
  -> unit
  -> (spawn_outcome, string) result
(** Freeze and admit the whole ordered flow before forking. The production AGENT_CORE
    callbacks bind/release the real candidate receipt in the durable approval
    queue. A summary reaches [on_summary] only after domain validation, exact
    receipt/provenance verification, and [Fsync_completed] completion.
    [on_finish] always permits active-owner cleanup, but only
    [Conclusive_terminalization] permits the caller to drain later owner work. *)

module For_testing : sig
  val run_outcome_of_observed_summary
    :  last_outcome:flow_outcome option
    -> Keeper_approval_queue_rules_types.hitl_context_summary option
    -> Exact_lane_run_registry.outcome * Yojson.Safe.t
  (** [last_outcome] is the branch the flow last recorded. A flow that ends
      with no summary reports that branch as the run's failure code, which is
      the only thing distinguishing a candidate exhaustion from a provider
      failure once the summary is absent. *)

  val system_prompt : unit -> (string, string) result

  val build_context_bundle
    :  entry:Keeper_approval_queue_rules_types.pending_approval
    -> Yojson.Safe.t

  val parse_summary
    :  generated_at:float
    -> model_run_id:string
    -> Yojson.Safe.t
    -> (Keeper_approval_queue_rules_types.hitl_context_summary, string) result

  type prepared_flow

  val with_outcome_sink : flow_outcome option ref -> (unit -> 'a) -> 'a
  (** Run [f] with a sink bound, so a test can execute a real flow and read
      back the branch it recorded. This is the binding the worker itself
      installs around every flow; exposing it is how the suite proves the
      sink is filled by the flow rather than only by a direct call. *)

  val prepare_flow
    :  entry:Keeper_approval_queue_rules_types.pending_approval
    -> (prepared_flow, string) result

  val execute_prepared_flow
    :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?clock:_ Eio.Time.clock
    -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
    -> prepared_flow
    -> execution_boundary

  type exact_transition =
    id:string
    -> input_hash:string
    -> sequence:int
    -> slot_id:string
    -> call_id:string
    -> plan_fingerprint:string
    -> request_body_sha256:string
    -> ( Keeper_approval_queue.exact_attempt_transition
       , Keeper_approval_queue.exact_attempt_error )
       result

  type exact_completion_transition =
    id:string
    -> input_hash:string
    -> sequence:int
    -> slot_id:string
    -> call_id:string
    -> plan_fingerprint:string
    -> request_body_sha256:string
    -> summary:Keeper_approval_queue_rules_types.hitl_context_summary
    -> ( Keeper_approval_queue.exact_attempt_transition
       , Keeper_approval_queue.exact_attempt_error )
       result

  type exact_quarantine_transition =
    id:string
    -> input_hash:string
    -> sequence:int
    -> slot_id:string
    -> call_id:string
    -> plan_fingerprint:string
    -> request_body_sha256:string
    -> cause:Keeper_approval_queue_rules_types.exact_attempt_quarantine_cause
    -> ( Keeper_approval_queue.exact_attempt_transition
       , Keeper_approval_queue.exact_attempt_error )
       result

  type exact_queue_ops

  val make_exact_queue_ops
    :  ?bind:exact_transition
    -> ?release_before_dispatch:exact_transition
    -> ?complete:exact_completion_transition
    -> ?quarantine:exact_quarantine_transition
    -> ?after_bind:(unit -> unit)
    -> unit
    -> exact_queue_ops

  val execute_prepared_flow_with_queue_ops
    :  queue_ops:exact_queue_ops
    -> ?cli_runner:Keeper_lane_cli_oneshot.runner
    -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
    -> ?clock:_ Eio.Time.clock
    -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
    -> prepared_flow
    -> execution_boundary
  (** The production flow with explicit durable queue transition authority.
      Tests can replace one transition while every other transition remains the
      ordinary production operation. *)

  val spawn_with_queue_ops
    :  queue_ops:exact_queue_ops
    -> ?cli_runner:Keeper_lane_cli_oneshot.runner
         (** Injectable effect edge for the cli lane-slot fallback walked
             after HTTP candidate exhaustion (RFC cli-runtimes-as-lane-slots);
             [None] spawns the real official client. *)
    -> sw:Eio.Switch.t
    -> entry:Keeper_approval_queue_rules_types.pending_approval
    -> on_summary:(Keeper_approval_queue_rules_types.hitl_context_summary -> unit)
    -> on_finish:(finish_outcome -> unit)
    -> unit
    -> (spawn_outcome, string) result
  (** Dependency injection over the same [spawn_with] lifecycle used by
      production [spawn]; the worker does not depend on test-only queue APIs. *)

  val flow_evidence : prepared_flow -> Agent_core.Exact_output.flow_evidence

  val summary_version : int
  val lane_id : string
end
