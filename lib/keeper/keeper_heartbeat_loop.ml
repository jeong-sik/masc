(* keeper_heartbeat_loop — the main heartbeat loop body and its helpers:
   presence sync, board event collection, in-turn liveness pulse,
   unified turn dispatch, exact cadence sleep, stage timing recording,
   and [run_heartbeat_loop].

   Extracted from keeper_keepalive.ml. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_memory
open Keeper_execution
open Keeper_keepalive_signal
module Observations = Keeper_heartbeat_loop_observations
module Cycle = Keeper_heartbeat_loop_cycle

(* Presence/identity sync extracted to
   [Keeper_heartbeat_loop_presence] (godfile decomp). *)
let effective_keepalive_meta = Keeper_heartbeat_loop_presence.effective_keepalive_meta
let repair_identity_drift_for_keepalive = Keeper_heartbeat_loop_presence.repair_identity_drift_for_keepalive
let keeper_agent_status = Keeper_heartbeat_loop_presence.keeper_agent_status
let note_turn_failures_preserved_after_heartbeat = Keeper_heartbeat_loop_presence.note_turn_failures_preserved_after_heartbeat
let sync_keeper_presence = Keeper_heartbeat_loop_presence.sync_keeper_presence

(* Pending board-event collection extracted to
   [Keeper_heartbeat_loop_board_events] (godfile decomp). *)
let collect_keepalive_board_events = Keeper_heartbeat_loop_board_events.collect_keepalive_board_events

let in_turn_liveness_pulse_interval_sec =
  Keeper_heartbeat_loop_in_turn_pulse.in_turn_liveness_pulse_interval_sec

let with_in_turn_liveness_pulse_for_test =
  Keeper_heartbeat_loop_in_turn_pulse.with_in_turn_liveness_pulse_for_test

let emit_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.emit_in_turn_liveness_pulse

let with_in_turn_liveness_pulse =
  Keeper_heartbeat_loop_in_turn_pulse.with_in_turn_liveness_pulse

(* Event-Layer stimulus intake extracted to [Keeper_heartbeat_stimulus_intake]
   (godfile decomp). Type + entry point are re-exported as transparent
   aliases so callers (incl. .mli consumers) stay byte-identical. *)
module Stimulus_intake = Keeper_heartbeat_stimulus_intake

let stimulus_urgency_to_string = Stimulus_intake.stimulus_urgency_to_string
let pending_board_event_of_stimulus = Stimulus_intake.pending_board_event_of_stimulus
let record_event_queue_stimulus_turn_started =
  Stimulus_intake.record_event_queue_stimulus_turn_started
;;

type heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  claimed_lease : Keeper_registry_event_queue.lease option;
  event_queue_claim_error : string option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

type turn_intake_admission =
  | Intake_admitted
  | Intake_lifecycle_blocked of Keeper_lifecycle_admission.autonomous_denial

let classify_turn_intake_admission ~lifecycle =
  match lifecycle with
  | Keeper_lifecycle_admission.Autonomous_denied denial ->
    Intake_lifecycle_blocked denial
  | Keeper_lifecycle_admission.Autonomous_admitted -> Intake_admitted
;;

let consume_single_heartbeat_stimulus = Stimulus_intake.consume_single_heartbeat_stimulus
let consume_board_stimulus_batch = Stimulus_intake.consume_board_stimulus_batch
let heartbeat_event_intake = Stimulus_intake.heartbeat_event_intake

(* Keepalive scheduling decision (record + decide function) extracted to
   [Keeper_heartbeat_loop_scheduling] (godfile decomp). *)
type keepalive_scheduling_decision = Keeper_heartbeat_loop_scheduling.keepalive_scheduling_decision = {
  turn_decision : Keeper_world_observation.keeper_cycle_decision;
  should_run_turn : bool;
  verdict_reasons : string list;
  channel : string;
}

let decide_keepalive_scheduling = Keeper_heartbeat_loop_scheduling.decide_keepalive_scheduling

let provider_timeout_observation_reasons =
  Observations.provider_timeout_observation_reasons
;;

let record_provider_timeout_observation =
  Observations.record_provider_timeout_observation
;;

(* #10008 fm3: canonical metric name for proactive-scheduler skip
   reasons. Labels: [("keeper", <name>); ("reason", <skip_reason>)]. *)
let proactive_skip_reason_metric = Keeper_metrics.(to_string ProactiveSkip)

let is_provider_timeout_error = Observations.is_provider_timeout_error

(** Run keeper cycle with holder diagnostics. *)
let run_keeper_cycle = Cycle.run_keeper_cycle

(* T6 audit: outcome of one keepalive cycle evaluation.

   [cycle_crashed = true] means either the catch-all in
   [run_keepalive_unified_turn] swallowed an exception to keep the
   keeper fiber alive, or the durable event-queue claim/settlement did
   not commit. The failure has already been recorded via
   [Keeper_registry.increment_turn_failures] (the same counter the
   unified-turn failure path in [Keeper_unified_turn_failure] uses),
   so the caller reads a non-zero [turn_fail_count] and dispatches
   [Turn_failed] instead of [Turn_succeeded]. Such a cycle must also
   NOT refresh the work-as-heartbeat lease; the count is observation and never
   terminates the Keeper lane. *)
type keepalive_turn_outcome = {
  meta : keeper_meta;
  cycle_crashed : bool;
}

exception Event_queue_settlement_failed of string

type board_attention_settlement_outcome =
  | Board_attention_settled of
      Keeper_board_attention_worker.settlement
  | Board_attention_settlement_deferred of
      Keeper_turn_admission.autonomous_block

let connector_attention_event_ids_of_stimuli stimuli =
  List.filter_map
    (fun (stimulus : Keeper_event_queue.stimulus) ->
      match stimulus.payload with
      | Keeper_event_queue.Connector_attention { event_id } -> Some event_id
      | Keeper_event_queue.Board_signal _
      | Keeper_event_queue.Board_attention _
      | Keeper_event_queue.Fusion_completed _
      | Keeper_event_queue.Bg_completed _
      | Keeper_event_queue.Schedule_due _
      | Keeper_event_queue.Bootstrap
      | Keeper_event_queue.Hitl_resolved _
      | Keeper_event_queue.Failure_judgment _
      | Keeper_event_queue.Manual_compaction_requested
      | Keeper_event_queue.Goal_assigned _ ->
        None)
    stimuli
;;

let record_schedule_due_turn_started_reactions ~ctx ~keeper_name stimuli =
  List.iter
    (fun (stimulus : Keeper_event_queue.stimulus) ->
       match stimulus.payload with
       | Keeper_event_queue.Schedule_due _ ->
         record_event_queue_stimulus_turn_started ~ctx ~keeper_name stimulus
       | Keeper_event_queue.Board_signal _
       | Keeper_event_queue.Board_attention _
       | Keeper_event_queue.Fusion_completed _
       | Keeper_event_queue.Bg_completed _
       | Keeper_event_queue.Bootstrap
       | Keeper_event_queue.Connector_attention _
       | Keeper_event_queue.Hitl_resolved _
       | Keeper_event_queue.Failure_judgment _
       | Keeper_event_queue.Manual_compaction_requested
       | Keeper_event_queue.Goal_assigned _ -> ())
    stimuli
;;

let mark_connector_attention_ignored_after_turn ~base_path ~keeper_name event_ids =
  match event_ids with
  | [] -> ()
  | _ :: _ ->
    (match
       Keeper_external_attention.mark_ignored
         ~base_path
         ~keeper_name
         ~event_ids
         ~reason:"connector_attention_turn_completed_without_direct_reply"
         ()
     with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "connector attention mark_ignored after turn failed keeper=%s events=[%s]: %s"
         keeper_name
         (String.concat "," event_ids)
         err)
;;

(* T6 audit: record a swallowed cycle exception as a turn failure.

   Catch-and-survive is intentional (the fiber must outlive the
   crash); the bug being fixed is that the crash was invisible to the
   scheduling/observation layer. Incrementing the registry counter routes the
   crash through the same [Turn_failed] telemetry channel as other failures. *)
let record_crashed_cycle_failure ~base_path ~keeper_name exn =
  (* Capture the backtrace before any other call can clobber it. *)
  let backtrace = Printexc.get_backtrace () in
  Keeper_registry.increment_turn_failures ~base_path keeper_name;
  Health.record_failure
    ~agent_name:keeper_name
    ~reason:(Keeper_types_profile.short_preview (Printexc.to_string exn));
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string CycleExceptions)
    ~labels:[ "keeper", keeper_name ]
    ();
  Log.Keeper.error
    "%s: keeper cycle exception (recorded as turn failure): %s%s"
    keeper_name
    (Printexc.to_string exn)
    (if String.equal backtrace "" then "" else "\n" ^ backtrace)
;;

let failure_judgment_of_stimuli = function
  | [ { Keeper_event_queue.payload =
          Keeper_event_queue.Failure_judgment judgment
      ; _
      } ] ->
    Ok (Some judgment)
  | stimuli ->
    if
      List.exists
        (fun (stimulus : Keeper_event_queue.stimulus) ->
           match stimulus.payload with
           | Keeper_event_queue.Failure_judgment _ -> true
           | Keeper_event_queue.Board_signal _
           | Keeper_event_queue.Board_attention _
           | Keeper_event_queue.Fusion_completed _
           | Keeper_event_queue.Bg_completed _
           | Keeper_event_queue.Schedule_due _
           | Keeper_event_queue.Bootstrap
           | Keeper_event_queue.Connector_attention _
           | Keeper_event_queue.Hitl_resolved _
           | Keeper_event_queue.Manual_compaction_requested
           | Keeper_event_queue.Goal_assigned _ ->
             false)
        stimuli
    then Error "failure judgment must be the sole stimulus in its event queue lease"
    else Ok None
;;

let manual_compaction_requested_of_stimuli = function
  | [ { Keeper_event_queue.payload = Manual_compaction_requested; _ } ] -> true
  | [] | [ _ ] | _ :: _ :: _ -> false
;;

let failure_judgment_successor
      ~arrived_at
      (failure : Keeper_unified_turn.turn_failure)
      judgment
      provenance
      detail
  =
  let payload : Keeper_event_queue.failure_judgment =
    { fj_runtime_id = failure.runtime_id
    ; fj_judgment = judgment
    ; fj_provenance = provenance
    ; fj_detail = detail
    }
  in
  { Keeper_event_queue.post_id = Keeper_event_queue.failure_judgment_post_id payload
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at
  ; payload = Keeper_event_queue.Failure_judgment payload
  }
;;

let settlement_of_failure
      ~settled_at
      ~compaction_consecutive_failures
      ~transcript_quarantine_consecutive_retries
      failure
  =
  let follow_route () =
    match failure.Keeper_unified_turn.route with
    | Keeper_runtime_failure_route.Retry_after_observed _ ->
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Retry_after_observed
    | Keeper_runtime_failure_route.Rotate_now _ ->
      Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Rotate_now
    | Keeper_runtime_failure_route.Escalate_judgment
        { judgment; provenance; detail } ->
      Keeper_registry_event_queue.Escalate
        { reason = Keeper_registry_event_queue.Failure_judgment_requested
        ; successor =
            Some
              (failure_judgment_successor
                 ~arrived_at:settled_at
                 failure
                 judgment
                 provenance
                 detail)
        }
  in
  (* RFC-0351 S0 / #25461: this failure is the
     [compaction_consecutive_failures + 1]-th compaction failure in a row when
     the disposition carries an in-lane compaction outcome; the counter itself
     is advanced by [compaction_outcome_of_cycle_outcome] on
     [keeper_meta.runtime.compaction_rt] after the settlement is decided. *)
  let attempts = compaction_consecutive_failures + 1 in
  let escalate_exhausted detail =
    Keeper_registry_event_queue.Escalate
      { reason =
          Keeper_registry_event_queue.Compaction_retry_exhausted
            { attempts; detail }
      ; successor = None
      }
  in
  match failure.Keeper_unified_turn.source_lease_disposition with
  | Keeper_unified_turn.Acknowledge_after_in_turn_handling ->
    Keeper_registry_event_queue.Ack
  | Keeper_unified_turn.Escalate_after_exact_output_terminal
      (Keeper_unified_turn.Exact_lane_unconfigured { source }) ->
    Keeper_registry_event_queue.Escalate
      { reason = Keeper_registry_event_queue.Compaction_exact_lane_unconfigured { source }
      ; successor = None
      }
  | Keeper_unified_turn.Escalate_after_exact_output_terminal
      (Keeper_unified_turn.Exact_execution_terminal { source; terminal }) ->
    Keeper_registry_event_queue.Escalate
      { reason =
          Keeper_registry_event_queue.Compaction_exact_output_terminal
            { source; terminal }
      ; successor = None
      }
  | Keeper_unified_turn.Requeue_after_context_compaction
      Keeper_unified_turn.Compaction_committed ->
    (* RFC-0351 S0 / #25538: a committed in-lane compaction is normally
       progress — but the streak now counts overflow episodes and only an
       overflow-free turn resets it, so reaching the ceiling *through
       commits* proves the committed savings cannot bring the context under
       the provider window (incompressible floor; measured: an LLM plan
       committing 920B, 0.07%, looped forever under the old
       reset-on-commit semantics). *)
    if attempts >= Keeper_meta_contract.compaction_retry_escalation_threshold
    then
      Keeper_registry_event_queue.Escalate
        { reason =
            Keeper_registry_event_queue.Compaction_floor_exceeded
              { attempts
              ; detail =
                  "compactions keep committing but the context re-overflows \
                   on consecutive attempts; the committed savings cannot \
                   bring the context under the provider window — retry \
                   suspended pending operator inspection"
              }
        ; successor = None
        }
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Context_compaction_retry
  | Keeper_unified_turn.Requeue_after_context_compaction
      (Keeper_unified_turn.Compaction_attempt_failed _) ->
    if attempts >= Keeper_meta_contract.compaction_retry_escalation_threshold
    then
      escalate_exhausted
        "in-lane provider-overflow compaction failed on consecutive attempts; \
         retry suspended pending operator inspection"
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Context_compaction_retry
  | Keeper_unified_turn.Requeue_after_transcript_quarantine ->
    (* #25296: the poisoned checkpoint is preserved unmodified by design, so
       every re-lease reloads the same incomplete transcript and the admission
       rejects it again — an unbounded requeue would re-fire the full turn
       pipeline on every heartbeat. This failure is the
       [transcript_quarantine_consecutive_retries + 1]-th quarantine in a row;
       the counter itself is advanced by
       [transcript_quarantine_outcome_of_cycle_outcome] on
       [keeper_meta.runtime] after the settlement is decided. Same ceiling
       shape as the compaction streak (2026-07-21 lesson: every exempt class
       needs its own accounting). *)
    let quarantine_attempts = transcript_quarantine_consecutive_retries + 1 in
    if
      quarantine_attempts
      >= Keeper_meta_contract.transcript_quarantine_retry_escalation_threshold
    then
      Keeper_registry_event_queue.Escalate
        { reason =
            Keeper_registry_event_queue.Transcript_quarantine_retry_exhausted
              { attempts = quarantine_attempts
              ; detail =
                  "transcript quarantine rejected the same preserved checkpoint \
                   on consecutive attempts; retry suspended pending operator \
                   inspection (recover or compact the checkpoint to clear)"
              }
        ; successor = None
        }
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Transcript_quarantine_retry
  | Keeper_unified_turn.Follow_failure_route_after_no_compaction { reason } ->
    if attempts >= Keeper_meta_contract.compaction_retry_escalation_threshold
    then
      escalate_exhausted
        (Printf.sprintf
           "in-lane provider-overflow compaction terminally declined (%s) on \
            consecutive attempts; retry suspended pending operator inspection"
           (Keeper_event_queue_state.no_compaction_reason_label reason))
    else follow_route ()
  | Keeper_unified_turn.Follow_failure_route -> follow_route ()
;;

let single_approved_resolution lease =
  match Keeper_registry_event_queue.lease_stimuli lease with
  | [ { Keeper_event_queue.payload =
          Hitl_resolved ({ decision = Hitl_approved; _ } as resolution)
      ; _
      } ] ->
    Some resolution
  | [] | [ _ ] | _ :: _ :: _ -> None
;;

(* RFC-0351 S0 / #25461: consecutive compaction failures tolerated before the
   settlement escalates instead of requeuing. A requeue is not an ack, so
   without a ceiling the same stimulus re-enters on every heartbeat cycle —
   measured at 102 failures / 104 compaction LLM calls in 74 minutes after the
   #25413 build went live. The constant lives in [Keeper_meta_contract] next to
   the [consecutive_failures] field it interprets, shared with the
   status/dashboard projections. *)
let compaction_retry_escalation_threshold =
  Keeper_meta_contract.compaction_retry_escalation_threshold

let settlement_of_cycle_outcome
      ~base_path
      ~settled_at
      ~stop_requested
      ~compaction_consecutive_failures
      ~transcript_quarantine_consecutive_retries
      ~lease
      outcome
  =
  match single_approved_resolution lease, outcome with
  | Some resolution, Some (Cycle.Completed _) ->
    (* RFC-0351 S0 / #25539: the approval wake's job is DELIVERY, not
       consumption. The old settlement requeued a completed turn whenever the
       grant was still unconsumed — but whether the model spends the grant is
       its own (non-deterministic) decision, so keepers that kept doing other
       work re-fired on every heartbeat cycle: 8,349 requeue receipts across
       8 keepers over ~42h, one idealist grant alone spinning 657 times. A
       completed turn settles as Ack regardless of grant state. This does not
       lose the operator's authorization: the grant remains durably spendable
       in the approval store ([approved_resolution_state] observes it) and
       visible on the resolved surface; a later matching attempt still
       consumes it. *)
    (match
       Keeper_approval_queue.approved_resolution_state
         ~base_path
         ~id:resolution.approval_id
     with
     | Ok Keeper_approval_queue.Resolution_consumed -> ()
     | Ok Keeper_approval_queue.Resolution_unconsumed ->
       Log.Keeper.warn
         "approval grant delivered but not consumed this turn approval=%s \
          keeper turn completed; grant remains durably spendable"
         resolution.approval_id
     | Error error ->
       Log.Keeper.error
         "approval resolution state unavailable approval=%s: %s (grant \
          remains durable; settlement follows the completed turn)"
         resolution.approval_id
         (Keeper_approval_queue.grant_error_to_string error));
    Keeper_registry_event_queue.Ack
  | ( Some _
    , ( Some
          ( Cycle.Cancelled _
          | Cycle.Skipped _
          | Cycle.Busy _
          | Cycle.Failed _
          | Cycle.Judgment_settled _
          | Cycle.Manual_compaction_applied _
          | Cycle.Manual_compaction_failed _
          | Cycle.Manual_compaction_not_applied _ )
      | None ) )
  (* A turn that did not complete has not delivered the wake; fall through to
     the ordinary outcome settlement below (busy/cancelled/failed requeue
     along their usual typed routes and the stimulus re-enters). *)
  | None, _ ->
    (match outcome with
  | Some (Cycle.Manual_compaction_applied _ as applied) ->
    (match Cycle.manual_compaction_followup_failure applied with
     | Some
         ({ Keeper_unified_turn.source_lease_disposition =
              Keeper_unified_turn.Follow_failure_route
          ; route =
              Keeper_runtime_failure_route.Escalate_judgment
                { judgment; provenance; detail }
          ; _
          } as failure) ->
       Keeper_registry_event_queue.Escalate
         { reason = Keeper_registry_event_queue.Failure_judgment_requested
         ; successor =
             Some
               (failure_judgment_successor
                  ~arrived_at:settled_at
                  failure
                  judgment
                  provenance
                  detail)
         }
     | Some _ | None -> Keeper_registry_event_queue.Ack)
  | Some (Cycle.Completed _) -> Keeper_registry_event_queue.Ack
  | Some (Cycle.Cancelled _) ->
    Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cancelled
  | Some (Cycle.Skipped _) ->
    Keeper_registry_event_queue.Requeue
      Keeper_registry_event_queue.Turn_not_scheduled
  | Some (Cycle.Busy _) ->
    Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cycle_busy
  | Some (Cycle.Failed { failure; _ }) ->
    settlement_of_failure
      ~settled_at
      ~compaction_consecutive_failures
      ~transcript_quarantine_consecutive_retries
      failure
  | Some (Cycle.Judgment_settled { outcome; _ }) ->
    (match outcome with
     | Cycle.Judgment_boundary_failed { detail } ->
       Keeper_registry_event_queue.Escalate
         { reason =
             Keeper_registry_event_queue.Failure_judgment_boundary_failed
               { detail }
         ; successor = None
         }
     | Cycle.Judgment_external_input_requested { judge_runtime_id; rationale } ->
       Keeper_registry_event_queue.Escalate
         { reason =
             Keeper_registry_event_queue.Failure_judgment_external_input_requested
               { judge_runtime_id; rationale }
         ; successor = None
         })
  | Some (Cycle.Manual_compaction_failed _) ->
    (* This failure is the [compaction_consecutive_failures + 1]-th in a row for
       this keeper; the counter itself is advanced by the compaction commit path
       on [keeper_meta.runtime.compaction_rt]. *)
    let attempts = compaction_consecutive_failures + 1 in
    if attempts >= compaction_retry_escalation_threshold
    then
      Keeper_registry_event_queue.Escalate
        { reason =
            Keeper_registry_event_queue.Compaction_retry_exhausted
              { attempts
              ; detail =
                  "manual compaction failed on consecutive attempts; retry \
                   suspended pending operator inspection"
              }
        ; successor = None
        }
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Context_compaction_retry
  | Some (Cycle.Manual_compaction_not_applied { no_compaction = { source; reason }; _ }) ->
    Keeper_registry_event_queue.No_compaction { source; reason }
  | None ->
    if stop_requested
    then Keeper_registry_event_queue.Requeue Keeper_registry_event_queue.Cancelled
    else
      Keeper_registry_event_queue.Requeue
        Keeper_registry_event_queue.Turn_not_scheduled
    )
;;

(* RFC-0351 S0 / #25461: pure mapping from a settled cycle outcome to the
   compaction-streak stamp on [keeper_meta.runtime.compaction_rt]. The manual
   lane counts [Manual_compaction_applied]/[Manual_compaction_failed]; the
   in-lane provider-overflow recovery joins the same streak through the
   failure's disposition so the settlement can bound its retries too. A
   terminal in-lane no-compaction counts as a failure — unlike the manual
   lane, where the terminal reason acks and consumes the compaction stimulus,
   the in-lane source lease carries a product event that requeues, so the same
   terminal reason re-fires on every retry. Dispositions with no in-lane
   compaction involvement leave the streak untouched: a generic turn failure
   proves nothing about compaction progress in either direction. *)
let compaction_outcome_of_cycle_outcome = function
  | Some (Cycle.Manual_compaction_applied _) -> Some `Committed
  | Some (Cycle.Manual_compaction_failed _) -> Some `Failed
  | Some (Cycle.Failed { failure; _ }) ->
    (match failure.Keeper_unified_turn.source_lease_disposition with
     | Keeper_unified_turn.Requeue_after_context_compaction
         Keeper_unified_turn.Compaction_committed ->
       (* #25538: an in-lane commit is still one provider-overflow episode.
          Advancing (not resetting) the streak is what lets an
          incompressible floor reach the ceiling; only an overflow-free
          completed turn — or the operator's manual commit — resets. *)
       Some `Overflow_episode_committed
     | Keeper_unified_turn.Requeue_after_context_compaction
         (Keeper_unified_turn.Compaction_attempt_failed _)
     | Keeper_unified_turn.Follow_failure_route_after_no_compaction _ ->
       Some `Failed
     | Keeper_unified_turn.Escalate_after_exact_output_terminal _ -> Some `Failed
     | Keeper_unified_turn.Follow_failure_route
     | Keeper_unified_turn.Acknowledge_after_in_turn_handling
     | Keeper_unified_turn.Requeue_after_transcript_quarantine -> None)
  | Some (Cycle.Completed _) -> Some `Recovered
  | Some
      ( Cycle.Cancelled _
      | Cycle.Skipped _
      | Cycle.Busy _
      | Cycle.Judgment_settled _
      | Cycle.Manual_compaction_not_applied _ )
  | None -> None
;;

(* #25296: pure mapping from a settled cycle outcome to the
   transcript-quarantine streak stamp on
   [keeper_meta.runtime.transcript_quarantine_consecutive_retries]. A failed
   turn whose disposition is [Requeue_after_transcript_quarantine] advances
   the streak — the settlement above reads it to escalate instead of
   requeuing once it reaches
   [Keeper_meta_contract.transcript_quarantine_retry_escalation_threshold].
   Any completed turn resets: the keeper is no longer pinned to the poisoned
   transcript. Other outcomes prove nothing about quarantine progress in
   either direction. *)
let transcript_quarantine_outcome_of_cycle_outcome = function
  | Some (Cycle.Failed { failure; _ }) ->
    (match failure.Keeper_unified_turn.source_lease_disposition with
     | Keeper_unified_turn.Requeue_after_transcript_quarantine -> Some `Retried
     | Keeper_unified_turn.Follow_failure_route
     | Keeper_unified_turn.Follow_failure_route_after_no_compaction _
     | Keeper_unified_turn.Requeue_after_context_compaction _
     | Keeper_unified_turn.Escalate_after_exact_output_terminal _
     | Keeper_unified_turn.Acknowledge_after_in_turn_handling -> None)
  | Some (Cycle.Completed _) -> Some `Recovered
  | Some
      ( Cycle.Cancelled _
      | Cycle.Skipped _
      | Cycle.Busy _
      | Cycle.Judgment_settled _
      | Cycle.Manual_compaction_applied _
      | Cycle.Manual_compaction_failed _
      | Cycle.Manual_compaction_not_applied _ )
  | None -> None
;;

let project_transition_outbox ~base_path ~keeper_name =
  Keeper_reaction_ledger.project_event_queue_transition_outbox_result
    ~base_path
    ~keeper_name
;;

let exact_terminal_source = function
  | Keeper_registry_event_queue.No_compaction
      { source
      ; reason = Keeper_event_queue_state.Exact_execution_terminal terminal
      } ->
    Some (source, terminal)
  | Keeper_registry_event_queue.Escalate
      { reason =
          Keeper_registry_event_queue.Compaction_exact_output_terminal
            { source; terminal }
      ; successor = None
      } ->
    Some (source, terminal)
  | Keeper_registry_event_queue.Ack
  | Keeper_registry_event_queue.No_compaction _
  | Keeper_registry_event_queue.Cancel_accepted _
  | Keeper_registry_event_queue.Transfer_accepted _
  | Keeper_registry_event_queue.Settle_from_source_terminal _
  | Keeper_registry_event_queue.Settle_exact _
  | Keeper_registry_event_queue.Requeue _
  | Keeper_registry_event_queue.Escalate _ ->
    None
;;

let exact_semantic_and_action = function
  | Keeper_registry_event_queue.Ack ->
    Some
      ( Keeper_registry_event_queue.Exact_ack
      , Keeper_registry_event_queue.Consume_source )
  | Keeper_registry_event_queue.No_compaction _ ->
    Some
      ( Keeper_registry_event_queue.Exact_no_compaction
      , Keeper_registry_event_queue.Consume_source )
  | Keeper_registry_event_queue.Requeue _ ->
    Some
      ( Keeper_registry_event_queue.Exact_requeue
      , Keeper_registry_event_queue.Resume_source )
  | Keeper_registry_event_queue.Escalate { successor = None; _ } ->
    Some
      ( Keeper_registry_event_queue.Exact_escalate
      , Keeper_registry_event_queue.Consume_source )
  | Keeper_registry_event_queue.Escalate { successor = Some successor; _ } ->
    Some
      ( Keeper_registry_event_queue.Exact_escalate
      , Keeper_registry_event_queue.Replace_with_successor successor )
  | Keeper_registry_event_queue.Cancel_accepted _
  | Keeper_registry_event_queue.Transfer_accepted _
  | Keeper_registry_event_queue.Settle_from_source_terminal _
  | Keeper_registry_event_queue.Settle_exact _ ->
    None
;;

let exact_disposition_matches_settlement
    (disposition : Keeper_registry_event_queue.exact_source_disposition)
    settlement =
  match exact_semantic_and_action settlement with
  | None -> false
  | Some (semantic, action) ->
    disposition.semantic = semantic
    && disposition.action = action
;;

let settle_claimed_lease
      ?(exact_execution = false)
      ~base_path
      ~keeper_name
      ~settled_at
      ~lease
      ~settlement
      ()
  =
  Eio.Cancel.protect (fun () ->
    if not exact_execution
    then
      Keeper_registry_event_queue.settle_result
        ~base_path
        keeper_name
        ~settled_at
        ~lease
        ~settlement
    else
      match Keeper_registry_event_queue.exact_execution_binding_result ~base_path keeper_name with
      | Error _ as error -> error
      | Ok None ->
        Keeper_registry_event_queue.settle_result
          ~base_path
          keeper_name
          ~settled_at
          ~lease
          ~settlement
      | Ok (Some binding) ->
        (match binding.status with
         | Keeper_registry_event_queue.Disposition_prepared disposition
         | Keeper_registry_event_queue.Checkpoint_commit_observed disposition ->
           if exact_disposition_matches_settlement disposition settlement
           then
             Keeper_registry_event_queue.finalize_exact_source_disposition_result
               ~base_path
               keeper_name
               ~settled_at
               ~lease
               ~disposition_id:disposition.disposition_id
           else
             Error
               "prepared exact disposition conflicts with the computed source settlement"
         | Keeper_registry_event_queue.Checkpoint_commit_intent _ ->
           Error
             "exact checkpoint commit is not durably observed; refusing source settlement"
         | Keeper_registry_event_queue.Dispatch_uncertain
         | Keeper_registry_event_queue.Terminal_quarantined _ ->
           (match exact_terminal_source settlement with
            | None ->
              Keeper_registry_event_queue.settle_exact_execution_result
                ~base_path
                keeper_name
                ~settled_at
                ~lease
                ~binding
                ~settlement
            | Some (source, terminal) ->
              let semantic =
                match settlement with
                | Keeper_registry_event_queue.No_compaction _ ->
                  Keeper_registry_event_queue.Exact_no_compaction
                | Keeper_registry_event_queue.Escalate _ ->
                  Keeper_registry_event_queue.Exact_escalate
                | Keeper_registry_event_queue.Ack
                | Keeper_registry_event_queue.Cancel_accepted _
                | Keeper_registry_event_queue.Transfer_accepted _
                | Keeper_registry_event_queue.Settle_from_source_terminal _
                | Keeper_registry_event_queue.Settle_exact _
                | Keeper_registry_event_queue.Requeue _ ->
                  assert false
              in
              (match
                 Keeper_registry_event_queue
                 .prepare_exact_source_disposition_result
                   ~base_path
                   keeper_name
                   ~lease
                   ~binding
                   ~source
                   ~outcome:
                     (Keeper_registry_event_queue.Terminal terminal.cause)
                   ~semantic
                   ~action:Keeper_registry_event_queue.Consume_source
                   ~prepared_at:settled_at
               with
               | Error _ as error -> error
               | Ok
                   ( _
                   , Keeper_registry_event_queue.Visible_sync_unconfirmed
                       detail ) ->
                 Error
                   ("exact source disposition became visible with unconfirmed sync; restart reconciliation required: "
                    ^ detail)
               | Ok
                   ( disposition
                   , Keeper_registry_event_queue.Fsync_completed ) ->
                 Keeper_registry_event_queue
                 .finalize_exact_source_disposition_result
                   ~base_path
                   keeper_name
                   ~settled_at
                   ~lease
                   ~disposition_id:disposition.disposition_id)))
;;

let exact_execution_guard ~base_path ~keeper_name ~lease =
  let binding_arguments
        (observation : Keeper_compaction_llm_summarizer.attempt_observation)
    =
    ( observation.slot_id
    , observation.call_id
    , observation.receipt_plan_fingerprint
    , observation.receipt_request_body_sha256 )
  in
  let before_dispatch observation =
    let slot_id, call_id, plan_fingerprint, request_body_sha256 =
      binding_arguments observation
    in
    Keeper_registry_event_queue.bind_exact_execution_result
      ~base_path
      keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  let release_before_dispatch observation =
    let slot_id, call_id, plan_fingerprint, request_body_sha256 =
      binding_arguments observation
    in
    Keeper_registry_event_queue.release_exact_execution_before_dispatch_result
      ~base_path
      keeper_name
      ~lease
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
  in
  let quarantine cause observation =
    let slot_id, call_id, plan_fingerprint, request_body_sha256 =
      binding_arguments observation
    in
    let terminal : Keeper_registry_event_queue.exact_execution_terminal =
      { cause; slot_id; call_id }
    in
    Keeper_registry_event_queue.quarantine_exact_execution_result
      ~base_path
      keeper_name
      ~lease
      ~terminal
      ~plan_fingerprint
      ~request_body_sha256
  in
  Keeper_compaction_llm_summarizer.
    { before_dispatch; release_before_dispatch; quarantine }
;;

let settlement_is_ack = function
  | Keeper_registry_event_queue.Ack
  | Keeper_registry_event_queue.No_compaction _
  | Keeper_registry_event_queue.Cancel_accepted _
  | Keeper_registry_event_queue.Transfer_accepted _ -> true
  | Keeper_registry_event_queue.Settle_from_source_terminal _ -> true
  | Keeper_registry_event_queue.Settle_exact
      { action = Keeper_registry_event_queue.Consume_source; _ } ->
    true
  | Keeper_registry_event_queue.Settle_exact
      { action =
          ( Keeper_registry_event_queue.Resume_source
          | Keeper_registry_event_queue.Replace_with_successor _ )
      ; _
      } ->
    false
  | Keeper_registry_event_queue.Requeue _
  | Keeper_registry_event_queue.Escalate _ ->
    false
;;

let settlement_is_exact_output_terminal = function
  | Keeper_registry_event_queue.No_compaction
      { reason = Keeper_event_queue_state.Exact_execution_terminal _; _ }
  | Keeper_registry_event_queue.Escalate
      { reason = Keeper_registry_event_queue.Compaction_exact_output_terminal _
      ; successor = None
      } ->
    true
  | Keeper_registry_event_queue.Ack
  | Keeper_registry_event_queue.No_compaction _
  | Keeper_registry_event_queue.Cancel_accepted _
  | Keeper_registry_event_queue.Transfer_accepted _
  | Keeper_registry_event_queue.Settle_from_source_terminal _
  | Keeper_registry_event_queue.Settle_exact
      { outcome = Keeper_registry_event_queue.Terminal _; _ } ->
    true
  | Keeper_registry_event_queue.Settle_exact
      { outcome = Keeper_registry_event_queue.Checkpoint_committed _; _ }
  | Keeper_registry_event_queue.Requeue _
  | Keeper_registry_event_queue.Escalate _ ->
    false
;;

let settlement_is_exact_output_cancellation = function
  | Keeper_registry_event_queue.No_compaction
      { reason =
          Keeper_event_queue_state.Exact_execution_terminal
            { cause =
                ( Keeper_event_queue_state.Execution_cancelled_after_dispatch
                | Keeper_event_queue_state.Terminal_persistence_failed )
            ; _
            }
      ; _
      }
  | Keeper_registry_event_queue.Escalate
      { reason =
          Keeper_registry_event_queue.Compaction_exact_output_terminal
            { terminal =
                { cause =
                    ( Keeper_event_queue_state.Execution_cancelled_after_dispatch
                    | Keeper_event_queue_state.Terminal_persistence_failed )
                ; _
                }
            ; _
            }
      ; successor = None
      } ->
    true
  | Keeper_registry_event_queue.Ack
  | Keeper_registry_event_queue.No_compaction _
  | Keeper_registry_event_queue.Cancel_accepted _
  | Keeper_registry_event_queue.Transfer_accepted _
  | Keeper_registry_event_queue.Settle_from_source_terminal _
  | Keeper_registry_event_queue.Settle_exact
      { outcome =
          Keeper_registry_event_queue.Terminal
            ( Keeper_event_queue_state.Execution_cancelled_after_dispatch
            | Keeper_event_queue_state.Terminal_persistence_failed )
      ; _
      } ->
    true
  | Keeper_registry_event_queue.Settle_exact _
  | Keeper_registry_event_queue.Requeue _
  | Keeper_registry_event_queue.Escalate _ ->
    false
;;

let check_cancellation_after_exact_terminal_settlement settlement =
  if settlement_is_exact_output_cancellation settlement then Eio.Fiber.check ()
;;

module For_testing = struct
  let exact_execution_guard = exact_execution_guard

  let check_cancellation_after_exact_terminal_settlement =
    check_cancellation_after_exact_terminal_settlement
  ;;
end

(* Pure: post-turn status event derived from the registry turn-failure
   counter. Extracted from the loop body so the crashed-cycle ->
   [Turn_failed] mapping is unit-testable. *)
let turn_status_event ~turn_fail_count : Keeper_state_machine.event =
  if turn_fail_count > 0
  then Keeper_state_machine.Turn_failed { consecutive = turn_fail_count }
  else Keeper_state_machine.Turn_succeeded
;;

let settle_board_attention_on_owner_lane ~base_path ~keeper_name =
  match
    Keeper_turn_admission.run_if_free
      ~base_path
      ~keeper_name
      (fun () ->
         Keeper_board_attention_worker.settle_one_completed
           ~base_path
           ~keeper_name)
  with
  | `Ran (Ok settlement) -> Ok (Board_attention_settled settlement)
  | `Ran (Error detail) -> Error detail
  | `Busy block -> Ok (Board_attention_settlement_deferred block)
;;

let run_keepalive_unified_turn
      ~(ctx : _ context)
      ~(meta_after_triage : keeper_meta)
      ~pending_board_events
      ~(stop : bool Atomic.t)
      ~(proactive_warmup_elapsed : bool)
      ~(reactive_wake : bool)
      ~(shared_context : Agent_sdk.Context.t)
  : keepalive_turn_outcome
  =
  if not proactive_warmup_elapsed
  then { meta = meta_after_triage; cycle_crashed = false }
  else (
    let consumed_stimuli = ref [] in
    let claimed_lease = ref None in
    let cycle_outcome_ref = ref None in
    let lease_settled = ref false in
    let settlement_failed = ref false in
    let record_settlement_failure message =
      settlement_failed := true;
      match !cycle_outcome_ref with
      | Some (Cycle.Failed _) ->
        (* The failed turn already recorded its failure counter.  The queue
           error remains explicit in the log and active durable lease. *)
        ()
      | Some
          ( Cycle.Completed _
          | Cycle.Cancelled _
          | Cycle.Skipped _
          | Cycle.Busy _
          | Cycle.Judgment_settled _
          | Cycle.Manual_compaction_failed _
          | Cycle.Manual_compaction_not_applied _
          | Cycle.Manual_compaction_applied _ )
      | None ->
        record_crashed_cycle_failure
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
          (Event_queue_settlement_failed message)
    in
    let requeue_unsettled reason =
      match !claimed_lease with
      | None -> ()
      | Some _ when !lease_settled -> ()
      | Some lease ->
        (match
           settle_claimed_lease
             ~base_path:ctx.config.base_path
             ~keeper_name:meta_after_triage.name
             ~settled_at:(Time_compat.now ())
             ~lease
             ~settlement:(Keeper_registry_event_queue.Requeue reason)
             ()
         with
         | Ok
             ( Keeper_registry_event_queue.Settled _
             | Keeper_registry_event_queue.Already_settled _ ) ->
           lease_settled := true
         | Ok (Keeper_registry_event_queue.Committed_followup_failed { detail; _ }) ->
           lease_settled := true;
           Log.Keeper.error
             "registry: requeue committed with follow-up failure keeper=%s: %s"
             meta_after_triage.name
             detail
         | Error message ->
           Log.Keeper.error
             "registry: failed to requeue unsettled lease keeper=%s: %s"
             meta_after_triage.name
             message)
    in
    let settle_exact_terminal_after_cancellation () =
      match !claimed_lease, !cycle_outcome_ref with
      | Some lease, Some outcome when not !lease_settled ->
        let settled_at = Time_compat.now () in
        let settlement =
          settlement_of_cycle_outcome
            ~base_path:ctx.config.base_path
            ~settled_at
            ~stop_requested:(Atomic.get stop)
            ~compaction_consecutive_failures:
              meta_after_triage.runtime.compaction_rt.consecutive_failures
            ~transcript_quarantine_consecutive_retries:
              meta_after_triage.runtime.transcript_quarantine_consecutive_retries
            ~lease
            (Some outcome)
        in
        if not (settlement_is_exact_output_terminal settlement)
        then false
        else (
          Eio.Cancel.protect (fun () ->
            match
              settle_claimed_lease
                ~exact_execution:true
                ~base_path:ctx.config.base_path
                ~keeper_name:meta_after_triage.name
                ~settled_at
                ~lease
                ~settlement
                ()
            with
            | Ok
                ( Keeper_registry_event_queue.Settled _
                | Keeper_registry_event_queue.Already_settled _ ) ->
              lease_settled := true;
              (match
                 project_transition_outbox
                   ~base_path:ctx.config.base_path
                   ~keeper_name:meta_after_triage.name
               with
               | Ok () -> ()
               | Error message -> record_settlement_failure message)
            | Ok (Keeper_registry_event_queue.Committed_followup_failed { detail; _ }) ->
              lease_settled := true;
              record_settlement_failure detail
            | Error message -> record_settlement_failure message);
          true)
      | None, _ | Some _, None | Some _, Some _ -> false
    in
    try
      (match
         project_transition_outbox
           ~base_path:ctx.config.base_path
           ~keeper_name:meta_after_triage.name
       with
       | Ok () -> ()
       | Error message -> raise (Event_queue_settlement_failed message));
      (match
         settle_board_attention_on_owner_lane
           ~base_path:ctx.config.base_path
           ~keeper_name:meta_after_triage.name
       with
       | Error detail ->
         raise (Keeper_board_attention_candidate.Candidate_unavailable detail)
       | Ok (Board_attention_settled Keeper_board_attention_worker.No_completed_partition) ->
         ()
       | Ok
           (Board_attention_settled
              (Keeper_board_attention_worker.Partition_settled
                 { candidate_id; continuation_wake = _ })) ->
         Log.Keeper.info
           "Board attention completed judgment settled on owner lane keeper=%s candidate=%s"
           meta_after_triage.name
           candidate_id
       | Ok
           (Board_attention_settlement_deferred
              (Keeper_turn_admission.Turn_busy in_flight)) ->
         Log.Keeper.debug
           "Board attention owner-lane settlement deferred keeper=%s holder=%s"
           meta_after_triage.name
           (match in_flight with
            | None -> "admission_in_progress"
            | Some { lane; _ } -> Keeper_turn_admission.lane_to_string lane)
       | Ok
           (Board_attention_settlement_deferred
              (Keeper_turn_admission.Chat_backlog
                 { pending_count; inflight_count })) ->
         Log.Keeper.info
           "Board attention owner-lane settlement deferred to chat backlog \
            keeper=%s pending=%d inflight=%d"
           meta_after_triage.name
           pending_count
           inflight_count
       | Ok
           (Board_attention_settlement_deferred
              (Keeper_turn_admission.Shutdown_requested operation_id)) ->
         Log.Keeper.info
           "Board attention owner-lane settlement deferred by shutdown \
            keeper=%s operation=%s"
           meta_after_triage.name
           (Keeper_shutdown_types.Operation_id.to_string operation_id));
      let event_intake =
        heartbeat_event_intake
          ~ctx
          ~meta_after_triage
          ~pending_board_events
      in
      consumed_stimuli := event_intake.consumed_stimuli;
      claimed_lease := event_intake.claimed_lease;
      let failure_judgment =
        match failure_judgment_of_stimuli event_intake.consumed_stimuli with
        | Ok judgment -> judgment
        | Error message -> raise (Event_queue_settlement_failed message)
      in
      let manual_compaction_requested =
        manual_compaction_requested_of_stimuli event_intake.consumed_stimuli
      in
      (match event_intake.event_queue_claim_error with
       | None -> ()
       | Some message -> record_settlement_failure message);
      let pending_board_events = event_intake.pending_board_events in
      let obs =
        Keeper_world_observation.observe
          ~pending_board_events:(Some pending_board_events)
          ~config:ctx.config
          ~meta:meta_after_triage
      in
      let scheduling =
        decide_keepalive_scheduling
          ~reactive_wake
          ~event_queue_triggers:event_intake.event_queue_triggers
          ~stop
          ~meta:meta_after_triage
          obs
      in
      let turn_decision = scheduling.turn_decision in
      (* Manual reconcile blocker check removed — keepers no longer get
         stuck behind sticky blockers. Failed turns record evidence via
         Keeper_registry; recovery is autonomous (next turn's observation)
         or operator-driven (board/keeper_chat), not blocker-driven. *)
      let should_run_turn = scheduling.should_run_turn in
      let verdict_strs = scheduling.verdict_reasons in
      let channel_str = scheduling.channel in
      if not should_run_turn
      then (
        (* #10008 fm3: emit per-reason skip counter so operators can
           see why proactive scheduler never fires for a given keeper.
           scholar/executor stayed at [proactive_count_total=0,
           last_proactive_ts=0.0] for 45+ min despite
           proactive_enabled=true — the info log alone buried the
           reason across many lines.  Labelled counter lets Grafana
           split [no_signal] vs [cooldown_pending] vs
           [scheduled_autonomous_disabled] so the bootstrap problem
           ("need signals to fire, need to fire to generate signals")
           is visible fleet-wide. *)
        List.iter
          (fun reason_str ->
             Otel_metric_store.inc_counter proactive_skip_reason_metric
               ~labels:[ "keeper", meta_after_triage.name; "reason", reason_str ]
               ())
          verdict_strs;
        (* #10940 follow-up — Otel_metric_store counters aggregate skip reasons
           across time, but operators need recent skip verdict context
           when diagnosing idle/quiet keepers. Stamping the registry on
           every skip preserves that local context. *)
        Keeper_registry.record_skip_reasons
          ~base_path:ctx.config.base_path
          meta_after_triage.name
          ~reasons:verdict_strs;
        Keeper_registry.touch_last_turn_ts
          ~base_path:ctx.config.base_path
          meta_after_triage.name;
        let paused_info =
          if meta_after_triage.paused
          then (
            let blocker_str =
              match meta_after_triage.runtime.last_blocker with
              | Some info ->
                let trimmed = String.trim info.detail in
                if String.equal trimmed ""
                then Keeper_meta_contract.blocker_class_to_string info.klass
                else trimmed
              | None -> "unknown"
            in
            let paused_since_sec =
              match
                Workspace_resilience.Time.parse_iso8601_opt meta_after_triage.updated_at
              with
              | Some ts -> int_of_float (max 0.0 (Time_compat.now () -. ts))
              | None -> -1
            in
            Printf.sprintf " blocker=%s paused_since=%ds" blocker_str paused_since_sec)
          else ""
        in
        let log_not_scheduled =
          match turn_decision.verdict with
          | Keeper_world_observation.Skip _ -> Log.Keeper.debug
          | Keeper_world_observation.Run _ -> Log.Keeper.info
        in
        log_not_scheduled
          "keepalive turn not scheduled for %s: should_run=%b channel=%s reasons=[%s] \
           idle=%ds since_last=%s%s"
          meta_after_triage.name
          turn_decision.should_run
          channel_str
          (String.concat "," verdict_strs)
          obs.idle_seconds
          (Keeper_keepalive_signal.format_since_last_scheduled_autonomous
             turn_decision.since_last_scheduled_autonomous)
          paused_info);
      if should_run_turn
      then
        Log.Keeper.info
          "keepalive turn scheduled for %s: channel=%s reasons=%s"
          meta_after_triage.name
          channel_str
          (String.concat "," verdict_strs);
      let tool_usage_entries =
        Keeper_registry.tool_usage_of
          ~base_path:ctx.config.base_path
          meta_after_triage.name
      in
      let available_tools =
        Keeper_tool_policy.keeper_model_tool_names ()
      in
      let tool_diversity_summary =
        let stats = Keeper_tool_diversity.stats_of_registry_entries tool_usage_entries in
        Keeper_tool_diversity.compute_diversity ~available_tools stats
      in
      Keeper_tool_diversity.record_underused_tool_metrics
        ~keeper_name:meta_after_triage.name
        ~available_tools
        tool_diversity_summary;
      let audit_wall_clock = Time_compat.now () in
      let tool_diversity_entropy =
        if tool_usage_entries = []
        then None
        else Some tool_diversity_summary.normalized_entropy
      in
      Keeper_decision_audit.append
        ~keeper_name:meta_after_triage.name
        (Keeper_decision_audit.make
           ~cycle_id:
             (Printf.sprintf
                "cycle-%s-%Ld"
                meta_after_triage.name
                (Int64.of_float (audit_wall_clock *. 1000.0)))
           ~keeper_name:meta_after_triage.name
           ~generation:meta_after_triage.runtime.nonce
           ~turn_verdict:turn_decision.verdict
           ~wall_clock:audit_wall_clock
           ?tool_diversity_entropy
           ());
      Keeper_decision_audit.flush_if_needed
        ~base_path:ctx.config.base_path
        ~keeper_name:meta_after_triage.name;
      let meta_after_cycle =
        if Atomic.get stop
        then meta_after_triage
        else if should_run_turn
        then (
          (* fd/disk pressure is pre-checked
             by [classify_turn_intake_admission] in [run_heartbeat_loop] BEFORE
             stimulus intake, so this branch is reached only when a turn is
             admitted. The four prior inline pressure gates here were removed: they
             ran AFTER intake had already consumed the stimulus, forcing a
             consume/requeue churn loop, and logged only at DEBUG (a silent skip). *)
          record_schedule_due_turn_started_reactions
            ~ctx
            ~keeper_name:meta_after_triage.name
            !consumed_stimuli;
          let event_bus = Event_bus_slots.get_keeper () in
          (* Preserve the typed resolution as input to the originating
             Keeper's external-effect Gate. It is not an OAS approval. *)
          let hitl_resolution =
            List.find_map
              (fun (stim : Keeper_event_queue.stimulus) ->
                match stim.Keeper_event_queue.payload with
                | Keeper_event_queue.Hitl_resolved resolution -> Some resolution
                | _ -> None)
              !consumed_stimuli
          in
          (* Non-board intake consumes exactly one stimulus per turn. Project
             its exact reply route without choosing between wake families or
             coalescing unrelated connector conversations. Board batches carry
             no continuation channel and therefore leave this [None]. *)
          let continuation_delivery_channel =
            match !consumed_stimuli with
            | [ { Keeper_event_queue.payload = Hitl_resolved resolution; _ } ]
              when Keeper_continuation_channel.is_routable resolution.channel ->
              Some resolution.channel
            | [ { Keeper_event_queue.payload = Fusion_completed completion; _ } ]
              when Keeper_continuation_channel.is_routable completion.channel ->
              Some completion.channel
            | [] | [ _ ] | _ :: _ :: _ -> None
          in
          (* #16 (38-bug campaign PR-5): [reactive_wake] tells us this cycle
             was triggered by an external signal rather than the proactive
             cadence tick, but by itself does not say *which* stimulus (or
             whether the event queue drained anything at all). Pairing it
             with [!consumed_stimuli] — already drained above, unchanged
             until the post-turn ack/requeue below — gives
             [mark_turn_started] a total, typed answer instead of the
             boolean the registry previously discarded. *)
          let wake : Keeper_registry.wake_reason =
            if reactive_wake
            then
              Keeper_registry.Woken
                (List.map
                   (fun (stim : Keeper_event_queue.stimulus) ->
                      stim.Keeper_event_queue.payload)
                   !consumed_stimuli)
            else Keeper_registry.Proactive_tick
          in
          let dispatch_guard =
            match !claimed_lease with
            | None -> None
            | Some lease ->
              Some
                (exact_execution_guard
                   ~base_path:ctx.config.base_path
                   ~keeper_name:meta_after_triage.name
                   ~lease)
          in
          let run_cycle () =
            run_keeper_cycle
              ?exact_execution_guard:dispatch_guard
              ?event_bus
              ?hitl_resolution
              ?continuation_delivery_channel
              ~ctx
              ~meta_after_triage
              ~stop
              ~obs
              ~turn_decision
              ~shared_context
              ~wake
              ?failure_judgment
              ~manual_compaction_requested
              ()
          in
          let cycle_outcome = run_cycle () in
          cycle_outcome_ref := Some cycle_outcome;
          Cycle.meta cycle_outcome)
        else meta_after_triage
      in
      (* Queue ownership follows the typed cycle outcome.  Pending removal,
         lease removal, an optional judgment successor, and the transition
         outbox receipt commit in one event-queue.json rename. *)
      (match !claimed_lease with
       | None ->
         (match !cycle_outcome_ref with
          | Some (Cycle.Failed { failure; _ }) ->
            (match failure.Keeper_unified_turn.source_lease_disposition with
             | Keeper_unified_turn.Requeue_after_context_compaction _
             | Keeper_unified_turn.Escalate_after_exact_output_terminal _
             | Keeper_unified_turn.Requeue_after_transcript_quarantine
             | Keeper_unified_turn.Acknowledge_after_in_turn_handling ->
               (* Intentionally a no-op, consistent with the context-compaction
                  arm above: these dispositions only requeue/acknowledge the
                  *owning lease's* stimuli, and an unleased cycle owns no lease
                  — there is no durable stimulus to requeue and none was
                  consumed (a lease is claimed before any stimulus is
                  processed, so [claimed_lease = None] means the turn ran
                  without queue work). Dropping the requeue intent here cannot
                  lose source work. *)
               ()
             | Keeper_unified_turn.Follow_failure_route
             | Keeper_unified_turn.Follow_failure_route_after_no_compaction _ ->
               (match failure.Keeper_unified_turn.route with
                | Keeper_runtime_failure_route.Escalate_judgment
                    { judgment; provenance; detail } ->
                  let successor =
                    failure_judgment_successor
                      ~arrived_at:(Time_compat.now ())
                      failure
                      judgment
                      provenance
                      detail
                  in
                  (match
                     Keeper_registry_event_queue.enqueue_durable_result
                       ~base_path:ctx.config.base_path
                       meta_after_triage.name
                       successor
                   with
                   | Ok () -> ()
                   | Error message ->
                     Log.Keeper.error
                       "registry: unleased failure judgment enqueue failed keeper=%s: %s"
                       meta_after_triage.name
                       message;
                     record_settlement_failure message)
                | Keeper_runtime_failure_route.Retry_after_observed _
                | Keeper_runtime_failure_route.Rotate_now _ ->
                  ()))
          | Some (Cycle.Judgment_settled _) ->
            record_settlement_failure
              "failure judgment completed without an owning event queue lease"
          | Some (Cycle.Manual_compaction_failed _) ->
            record_settlement_failure
              "manual compaction failed without an owning event queue lease"
          | Some (Cycle.Manual_compaction_not_applied _) ->
            record_settlement_failure
              "manual no-compaction terminal has no owning event queue lease"
          | Some (Cycle.Manual_compaction_applied _) ->
            record_settlement_failure
              "manual compaction completed without an owning event queue lease"
          | Some
              ( Cycle.Completed _
              | Cycle.Cancelled _
              | Cycle.Skipped _
              | Cycle.Busy _ )
          | None ->
            ())
       | Some lease ->
         let settled_at = Time_compat.now () in
         let settlement =
           settlement_of_cycle_outcome
             ~base_path:ctx.config.base_path
             ~settled_at
             ~stop_requested:(Atomic.get stop)
             ~compaction_consecutive_failures:
               meta_after_triage.runtime.compaction_rt.consecutive_failures
             ~transcript_quarantine_consecutive_retries:
               meta_after_triage.runtime
                 .transcript_quarantine_consecutive_retries
             ~lease
             !cycle_outcome_ref
         in
         (* RFC-0351 S0 / #25461: advance the compaction streak the settlement
            above just read. Ordering matters — the settlement decides
            requeue-vs-escalate from the streak *before* this failure, and this
            stamp records the failure for the next cycle. *)
         (let compaction_outcome =
            compaction_outcome_of_cycle_outcome !cycle_outcome_ref
          in
          match compaction_outcome with
          | None -> ()
          | Some `Recovered
            when meta_after_triage.runtime.compaction_rt.consecutive_failures
                 = 0 ->
            (* Streak already clear: skip the read-modify-write that every
               healthy completed turn would otherwise pay. *)
            ()
          | Some outcome ->
            (match
               Keeper_meta_store.persist_compaction_outcome
                 ctx.config
                 ~keeper_name:meta_after_triage.name
                 ~outcome
             with
             | Ok (`Persisted | `No_durable_meta) -> ()
             | Error message ->
               Log.Keeper.warn
                 "compaction outcome counter not persisted keeper=%s: %s"
                 meta_after_triage.name
                 message));
         (* #25296: advance the transcript-quarantine streak the settlement
            above just read — same ordering rule as the compaction streak. *)
         (let quarantine_outcome =
            transcript_quarantine_outcome_of_cycle_outcome !cycle_outcome_ref
          in
          match quarantine_outcome with
          | None -> ()
          | Some `Recovered
            when meta_after_triage.runtime
                   .transcript_quarantine_consecutive_retries
                 = 0 ->
            (* Streak already clear: skip the read-modify-write that every
               healthy completed turn would otherwise pay. *)
            ()
          | Some outcome ->
            (match
               Keeper_meta_store.persist_transcript_quarantine_outcome
                 ctx.config
                 ~keeper_name:meta_after_triage.name
                 ~outcome
             with
             | Ok (`Persisted | `No_durable_meta) -> ()
             | Error message ->
               Log.Keeper.warn
                 "transcript quarantine outcome counter not persisted keeper=%s: %s"
                 meta_after_triage.name
                 message));
         (match
            settle_claimed_lease
              ~exact_execution:true
              ~base_path:ctx.config.base_path
              ~keeper_name:meta_after_triage.name
              ~settled_at
              ~lease
              ~settlement
              ()
          with
          | Error message ->
            Log.Keeper.error
              "registry: durable lease settlement failed keeper=%s: %s"
              meta_after_triage.name
              message;
            record_settlement_failure message
          | Ok
              ( Keeper_registry_event_queue.Settled _
              | Keeper_registry_event_queue.Already_settled _ ) ->
            lease_settled := true;
            (match
               project_transition_outbox
                 ~base_path:ctx.config.base_path
                 ~keeper_name:meta_after_triage.name
             with
             | Error message -> raise (Event_queue_settlement_failed message)
             | Ok () -> ());
            check_cancellation_after_exact_terminal_settlement settlement;
            if settlement_is_ack settlement
            then
              mark_connector_attention_ignored_after_turn
                ~base_path:ctx.config.base_path
                ~keeper_name:meta_after_triage.name
                (connector_attention_event_ids_of_stimuli !consumed_stimuli)
          | Ok (Keeper_registry_event_queue.Committed_followup_failed { detail; _ }) ->
            lease_settled := true;
            Log.Keeper.error
              "registry: settlement committed with follow-up failure keeper=%s: %s"
              meta_after_triage.name
              detail;
            record_settlement_failure detail;
            check_cancellation_after_exact_terminal_settlement settlement));
      { meta = meta_after_cycle; cycle_crashed = !settlement_failed }
    with
    | Eio.Cancel.Cancelled _ as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      if not (settle_exact_terminal_after_cancellation ())
      then requeue_unsettled Keeper_registry_event_queue.Cancelled;
      Printexc.raise_with_backtrace e backtrace
    | Keeper_registry.Keeper_fiber_crash as e ->
      let backtrace = Printexc.get_raw_backtrace () in
      requeue_unsettled Keeper_registry_event_queue.Cycle_crashed;
      Printexc.raise_with_backtrace e backtrace
    | exn ->
      requeue_unsettled Keeper_registry_event_queue.Cycle_crashed;
      (* T6 audit: keep the fiber alive, but surface the crash as a
         turn failure so the caller does not dispatch
         [Turn_succeeded] for a cycle that never completed. *)
      record_crashed_cycle_failure
        ~base_path:ctx.config.base_path
        ~keeper_name:meta_after_triage.name
        exn;
      { meta = meta_after_triage; cycle_crashed = true })
;;

let refresh_work_as_heartbeat = Keeper_heartbeat_loop_refresh_work.refresh_work_as_heartbeat

let maybe_write_heartbeat_snapshot = Keeper_heartbeat_loop_snapshot_timing.maybe_write_heartbeat_snapshot
let record_keepalive_stage_timing = Keeper_heartbeat_loop_snapshot_timing.record_keepalive_stage_timing

(* Spec navigation (OCaml -> TLA+) — plan §19 Cycle 27 anchor for
   B1 (Heartbeat).  Authoritative spec mirror is
   specs/keeper-state-machine/KeeperHeartbeat.tla (Cycle 7 / Tier B1,
   PR #11408).

   The spec preamble cites this module by function name
   ([run_heartbeat_loop]); it used to carry a line number but iter 64
   N-2.a removed it — function names are stable, line numbers drift, and
   spec-preamble line refs are now guarded by
   scripts/audit-tla-ml-line-refs.sh (iter 64 N-2.c).  This comment is
   the authoritative reverse-direction citation; the OCaml-docstring
   side is guarded by scripts/audit-ocaml-spec-nav-line-refs.sh
   (iter 72 R-1.a).

   Action mapping (TLA+ -> OCaml):
     WakeupSignal     external code sets [wakeup] Atomic to true
                      (e.g., wakeup_keeper / operator_resume).
     HeartbeatTick    [Keeper_keepalive_signal.interruptible_sleep]
                      consumes the wakeup via
                      [Atomic.compare_and_set wakeup true false], then
                      the loop body services the pending event.
     TurnComplete     turn body finishes; loop returns to next sleep
                      cycle.
     MissedWakeup     bug action — the wakeup is observed and cleared
                      but the loop fails to start a turn.  In OCaml
                      this would be a regression where the
                      compare_and_set succeeds but the surrounding
                      branch returns early without dispatching.  The
                      spec's NoMissedSignals invariant catches that
                      drift; in code, the structural invariant is
                      that every successful compare_and_set returns [Woken]
                      and recurs directly into dispatch without another
                      policy decision or sleep. *)

let run_heartbeat_loop
      ~proactive_warmup_sec
      (ctx : _ context)
      (m : keeper_meta)
      (stop : bool Atomic.t)
      ~(wakeup : bool Atomic.t)
  : unit
  =
  let keepalive_started_ts = Time_compat.now () in
  let snapshot_interval_sec () =
    Runtime_params.get Runtime_settings.keeper_snapshot_sec
  in
  let last_snapshot_ts = ref 0.0 in
  let consecutive_failures = ref 0 in
  (* Cycle 43: KeeperHeartbeat.tla [turn_state] mirror. Single-fiber by
     construction — only this loop body reads/writes the ref. *)
  let turn_running = ref false in
  (* Phase 0: per-stage timing ring buffer.
     ring_size is read once at fiber start — mid-flight resize requires
     ring buffer reallocation, so new values apply on next fiber restart. *)
  let ring_sz = Keeper_keepalive_signal.stage_timing_ring_size () in
  let timing_ring =
    Array.make
      ring_sz
      { presence_ms = 0.0
      ; snapshot_ms = 0.0
      ; board_ms = 0.0
      ; turn_ms = 0.0
      }
  in
  let timing_cursor = ref 0 in
  let timing_filled = ref 0 in
  (* Phase 1: work-as-heartbeat freshness tracking.
     Updated ONLY on Workspace.heartbeat success after turn. *)
  let last_successful_heartbeat_ts = ref (Time_compat.now ()) in
  let work_as_hb () = Runtime_params.get Runtime_settings.keeper_work_as_hb_enabled in
  let _max_silence () =
    Runtime_params.get Runtime_settings.keeper_work_as_hb_max_silence_sec
  in
  (* Persistent OAS Context.t — created once per keeper lifecycle.
     OAS Context.t is a mutable cross-turn state container for values
     written directly into the shared context. This preserves shared
     metadata across turns, but per-turn context_injector-local timing
     and tool-call counters are recreated inside run_turn and therefore
     do not accumulate for the full keeper lifecycle. *)
  let shared_context = Agent_sdk.Context.create () in
  (* Mtime-based change detection for keeper meta disk reads.
     Avoids re-parsing the JSON file on every heartbeat cycle when
     no operator has modified it.  Initialized to 0.0 so the first
     cycle always reads. *)
  let last_meta_mtime = ref 0.0 in
  (* Wake-source carry (thundering-herd fix). Records whether the most recent
     sleep ended via an external broadcast wakeup ([Woken]) or this keeper's own
     cadence timer ([Timeout]). Read at turn dispatch so a broadcast-driven early
     wake does not let the GLOBAL task backlog drive a turn on every keeper at
     once. Single-fiber owned, like the other loop-local refs above. *)
  let last_wake_source = ref Keeper_keepalive_signal.Timeout in
  let rec loop () =
    if Atomic.get stop
    then ()
    else (
      (* Yield before each heartbeat cycle to prevent N keeper fibers
               from monopolizing the Eio scheduler during CPU-bound phases
               (tool filtering, snapshot construction, prompt building). *)
      Eio_guard.fair_yield ();
      (* Phase 0: timing markers *)
      let t_presence_start = Time_compat.now () in
      let disk_meta_opt, new_meta_mtime =
        match read_meta_if_changed ctx.config m.name ~last_mtime:!last_meta_mtime with
        | Some (latest, new_mtime) -> Some latest, Some new_mtime
        | None -> None, None
      in
      Option.iter (fun new_mtime -> last_meta_mtime := new_mtime) new_meta_mtime;
      let meta_current =
        effective_keepalive_meta
          ~base_path:ctx.config.base_path
          ~fallback:m
          ~disk_meta_opt
      in
      let meta_current =
        match repair_identity_drift_for_keepalive ~ctx meta_current with
        | Some repaired -> repaired
        | None -> meta_current
      in
      (* Sync disk meta to registry so dashboard reads live values.  #5364.
         When disk meta is unchanged we still prefer the registry copy because
         runtime writes update it via the write_meta hook. This keeps
         continuity/runtime fields fresh even if disk mtime does not advance
         between rapid writes inside a single loop window. *)
      let registry_meta =
        match Keeper_registry.get ~base_path:ctx.config.base_path meta_current.name with
        | Some entry -> entry.meta
        | None -> m
      in
      if meta_current != registry_meta
      then
        Keeper_registry.update_meta
          ~base_path:ctx.config.base_path
          meta_current.name
          meta_current;
      (* A live lane evaluates every configured heartbeat tick. Busy/idle
         labels, observer count, and prior activity never suppress the cycle;
         an explicit wake atomically cuts the sleep for this Keeper only. *)
      let meta_current =
        (* Phase 1: sync presence and emit heartbeat metric *)
        let meta_current =
          sync_keeper_presence
            ~ctx
            ~meta_current
            ~consecutive_failures
            ~last_successful_heartbeat_ts
        in
        if !consecutive_failures > 0
        then
          Keeper_registry.set_failure_reason
            ~base_path:ctx.config.base_path
            m.name
            (Some (Keeper_registry.Heartbeat_consecutive_failures !consecutive_failures));
        meta_current
      in
        let t_presence_end = Time_compat.now () in
        let now_ts = t_presence_end in
        let t_snapshot_start = now_ts in
        maybe_write_heartbeat_snapshot
          ~ctx
          ~meta_current
          ~now_ts
          ~last_snapshot_ts
          ~snapshot_interval_sec:(snapshot_interval_sec ())
          ~timing_ring
          ~timing_filled:!timing_filled;
        let t_snapshot_end = Time_compat.now () in
        let t_board_start = t_snapshot_end in
        (* Compute warmup state BEFORE board collection so cursor
                 is not advanced while keeper cannot act on events. *)
        let proactive_warmup_elapsed =
          proactive_warmup_sec <= 0
          || now_ts -. keepalive_started_ts >= float_of_int proactive_warmup_sec
        in
        (* Lifecycle state is evaluated before durable stimulus intake. Resource
           pressure remains observable but cannot pre-empt every Keeper lane;
           concrete I/O boundaries report their own failures explicitly. *)
        let lifecycle_state =
          Keeper_lifecycle_admission.state
            ~paused:meta_current.paused
            ~latched_reason:meta_current.latched_reason
        in
        let intake_admission =
          classify_turn_intake_admission
            ~lifecycle:
              (Keeper_lifecycle_admission.admit_autonomous lifecycle_state)
        in
        let admitted_turn =
          match intake_admission with
          | Intake_admitted -> true
          | Intake_lifecycle_blocked _ -> false
        in
        let lifecycle_blocked =
          match intake_admission with
          | Intake_lifecycle_blocked _ -> true
          | Intake_admitted -> false
        in
        let terminal_lifecycle_blocked =
          match intake_admission with
          | Intake_lifecycle_blocked
              Keeper_lifecycle_admission.Autonomous_dead_tombstone -> true
          | Intake_lifecycle_blocked (Keeper_lifecycle_admission.Autonomous_paused _) -> false
          | Intake_admitted -> false
        in
        (match intake_admission with
         | Intake_admitted -> ()
         | Intake_lifecycle_blocked denial ->
           let reason =
             Keeper_lifecycle_admission.autonomous_denial_to_wire denial
           in
           Otel_metric_store.inc_counter
             Keeper_metrics.(to_string LifecycleDispatchRejections)
             ~labels:
               [ "keeper", meta_current.name
               ; "event", "heartbeat_pre_intake"
               ; "reason", reason
               ]
             ();
           Keeper_registry.record_skip_reasons
             ~base_path:ctx.config.base_path
             meta_current.name
             ~reasons:[ "lifecycle_" ^ reason ];
           Log.Keeper.info
             "%s: heartbeat intake denied by lifecycle admission: %s"
             meta_current.name
             reason;
           if terminal_lifecycle_blocked
           then
             (* A dead tombstone owns no runnable lane. Ordinary pause keeps
                its lane parked so an explicit resume remains local. *)
             Atomic.set stop true
           else
             Keeper_registry.touch_last_turn_ts
               ~base_path:ctx.config.base_path
               meta_current.name
         );
        let pending_board_events, meta_after_triage =
          if admitted_turn
          then
            collect_keepalive_board_events
              ~ctx
              ~meta_current
              ~proactive_warmup_elapsed
          else [], meta_current
        in
        let t_board_end = Time_compat.now () in
        let t_turn_start = t_board_end in
        let turn_outcome =
          if not admitted_turn
          then { meta = meta_current; cycle_crashed = false }
          else (
            (* Cycle 43: KeeperHeartbeat.tla TurnComplete bracket — the
               [turn_running] flag toggles around the dispatch and the
               pre/post guards mirror the spec's [turn_state] transition
               "running" -> "idle". *)
            turn_running := true;
            (* [Woken] => this cycle was triggered by an external broadcast, not
               the keeper's own cadence; suppress global-backlog-driven turns to
               avoid the all-keeper stampede. *)
            let reactive_wake =
              match !last_wake_source with
              | Keeper_keepalive_signal.Woken -> true
              | Keeper_keepalive_signal.Timeout | Keeper_keepalive_signal.Stopped ->
                false
            in
            let r =
              run_keepalive_unified_turn
                ~ctx
                ~meta_after_triage
                ~pending_board_events
                ~stop
                ~proactive_warmup_elapsed
                ~reactive_wake
                ~shared_context
            in
            Keeper_keepalive_signal.pre_turn_complete_heartbeat ~turn_running;
            turn_running := false;
            Keeper_keepalive_signal.post_turn_complete_heartbeat ~turn_running;
            r)
        in
        let meta_after_proactive = turn_outcome.meta in
        if not lifecycle_blocked
        then (
          (* The registry tracks failure count as observation. A
             lifecycle-blocked cycle did not run a turn and must not emit a
             false [Turn_succeeded]. *)
          let turn_fail_count =
            Keeper_registry.get_turn_failures
              ~base_path:ctx.config.base_path
              m.name
          in
          (* RFC-0002: dispatch turn status event *)
          Keeper_keepalive_signal.dispatch_keepalive_event
            ~ctx
            ~keeper_name:m.name
            (turn_status_event
               ~turn_fail_count);
          if turn_fail_count > 0
          then
            Keeper_registry.set_failure_reason
              ~base_path:ctx.config.base_path
              m.name
              (Some (Keeper_registry.Turn_consecutive_failures turn_fail_count));
          (* Phase 1: work-as-heartbeat — renew point (b).
             After turn, call Workspace.heartbeat to prove workspace I/O health.
             On success: refresh freshness lease + reset consecutive_failures.
             On failure: leave timestamp unchanged → presence sync resumes next cycle.
             T6 audit: a crashed cycle proves nothing about health — do not
             refresh the lease or reset consecutive_failures for it. *)
          if turn_outcome.cycle_crashed
          then
            Log.Keeper.info
              "%s: skipping work-as-heartbeat refresh after crashed keepalive cycle"
              m.name
          else
            refresh_work_as_heartbeat
              ~ctx
              ~meta_after_proactive
              ~proactive_warmup_elapsed
              ~work_as_hb
              ~last_successful_heartbeat_ts
              ~consecutive_failures);
        let t_turn_end = Time_compat.now () in
        let interval =
          float_of_int (Keeper_heartbeat_snapshot.keepalive_interval_sec ())
        in
        (* Phase 0: push stage timing to ring buffer *)
        record_keepalive_stage_timing
          ~timing_ring
          ~timing_cursor
          ~timing_filled
          ~ring_sz
          ~t_presence_start
          ~t_presence_end
          ~t_snapshot_start
          ~t_snapshot_end
          ~t_board_start
          ~t_board_end
          ~t_turn_start
          ~t_turn_end;
        (* Carry the inter-cycle sleep result into the next iteration so the
           turn evaluator can distinguish a broadcast wakeup ([Woken]) from this
           keeper's configured cadence ([Timeout]). *)
        last_wake_source :=
          Keeper_keepalive_signal.interruptible_sleep
            ~clock:ctx.clock
            ~stop
            ~wakeup
            interval;
      if Atomic.get stop then () else loop ())
  in
  loop ()
;;
