(** Keeper cycle execution with error-class
    handling, extracted from [keeper_heartbeat_loop.ml] (godfile
    decomp).

    [run_keeper_cycle] wraps a single keeper-cycle execution
    in an [in_turn_liveness_pulse] heartbeat fiber, then triages the
    result. The function is the canonical error-classification layer
    for the keepalive loop:

    - Fatal environment errors (Eio switch/net unavailable) → ERROR
      log + [metric_keeper_heartbeat_failures] tick (phase=
      fatal_environment) + [Keeper_registry.set_failure_reason
      Exception] + raises [Keeper_registry.Keeper_fiber_crash] for
      the supervisor to handle.

    - Provider-timeout errors → provider-timeout strike-counter bump (seeded from
      [prior_provider_timeout_strikes]) + persistent failure
      reason + observation recording + [Keeper_failure_policy.decide]
      kill/keep decision + [metric_keeper_provider_timeout_strike]
      tick with policy-derived outcome label.

    - Any other [Error err] → DEBUG log + re-read meta (with
      [metric_keeper_meta_read_failures] on read failure +
      Site=none_after_failure or error_after_failure label).

    - [Ok updated] → reset budget exhaustion + clear provider-timeout
      failure reason + return updated meta.

    Pure helper move — no callback injection, all references reach
    external modules (Keeper_unified_turn, Agent_sdk, Log, Otel_metric_store,
    Keeper_metrics, Keeper_registry, Keeper_turn_holders,
    Keeper_failure_policy) or other siblings
    ([Keeper_heartbeat_loop_in_turn_pulse], [Observations]). *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
module In_turn_pulse = Keeper_heartbeat_loop_in_turn_pulse
module Observations = Keeper_heartbeat_loop_observations

type cycle_outcome =
  | Completed of keeper_meta
  | Cancelled of keeper_meta
  | Skipped of keeper_meta
  | Failed of
      { meta : keeper_meta
      ; failure : Keeper_unified_turn.turn_failure
      }
  | Busy of
      { meta : keeper_meta
      ; block : Keeper_turn_admission.autonomous_block
      }
  | Judgment_settled of
      { meta : keeper_meta
      ; outcome : failure_judgment_terminal
      }

and failure_judgment_terminal =
  | Judgment_boundary_failed of { detail : string }
  | Judgment_operator_required of
      { judge_runtime_id : string
      ; rationale : string
      }

let meta = function
  | Completed meta
  | Cancelled meta
  | Skipped meta
  | Failed { meta; _ }
  | Busy { meta; _ }
  | Judgment_settled { meta; _ } ->
    meta
;;

let record_failure_judgment_outcome
      ~keeper_name
      (request : Keeper_event_queue.failure_judgment)
      outcome
  =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string FailureJudgmentOutcome)
    ~labels:
      [ "keeper", keeper_name
      ; "outcome", outcome
      ; ( "judgment_class"
        , Keeper_runtime_failure_route.judgment_class_label request.fj_judgment )
      ; ( "provenance"
        , Keeper_runtime_failure_route.judgment_provenance_label
            request.fj_provenance )
      ]
    ()
;;

let prepare_failure_judgment_turn
      ~base_path
      ~keeper_name
      ~(request : Keeper_event_queue.failure_judgment)
      (obs : Keeper_world_observation.world_observation)
  =
  match Keeper_failure_judge.run ~base_path ~keeper_name request with
  | Error error ->
    let detail =
      Keeper_failure_judge.error_detail error
      |> Keeper_internal_error.cap_blocker_detail
    in
    let disposition = Keeper_failure_judge.error_disposition error in
    let outcome = Keeper_failure_judge.error_disposition_label disposition in
    record_failure_judgment_outcome ~keeper_name request outcome;
    Log.Keeper.warn
      "%s: independent failure judgment failed outcome=%s class=%s provenance=%s: %s"
      keeper_name
      outcome
      (Keeper_runtime_failure_route.judgment_class_label request.fj_judgment)
      (Keeper_runtime_failure_route.judgment_provenance_label request.fj_provenance)
      detail;
    (match disposition with
     | Keeper_failure_judge.Escalate_judge_failure ->
       `Settle (Judgment_boundary_failed { detail }))
  | Ok { runtime_id = judge_runtime_id; verdict } ->
    Keeper_pacing_shadow.observe_success
      ~keeper_name
      ~runtime_id:judge_runtime_id;
    (match verdict with
     | Keeper_failure_judgment_contract.Resume_with_guidance
         { guidance; rationale } ->
       (match
          Keeper_world_observation.apply_failure_judgment_guidance
            ~post_id:(Keeper_event_queue.failure_judgment_post_id request)
            ~judge_runtime_id
            ~guidance
            ~rationale
            obs.pending_board_events
        with
        | Error detail ->
          let detail = Keeper_internal_error.cap_blocker_detail detail in
          record_failure_judgment_outcome
            ~keeper_name
            request
            (Keeper_failure_judge.error_disposition_label
               Keeper_failure_judge.Escalate_judge_failure);
          Log.Keeper.error
            "%s: independent failure judgment could not bind guidance to its \
             observation: %s"
            keeper_name
            detail;
          `Settle (Judgment_boundary_failed { detail })
        | Ok pending_board_events ->
          record_failure_judgment_outcome
            ~keeper_name
            request
            (Keeper_failure_judgment_contract.decision_label verdict);
          Log.Keeper.info
            "%s: independent failure judgment admitted action turn \
             judge_runtime=%s class=%s provenance=%s"
            keeper_name
            judge_runtime_id
            (Keeper_runtime_failure_route.judgment_class_label request.fj_judgment)
            (Keeper_runtime_failure_route.judgment_provenance_label
               request.fj_provenance);
          `Run { obs with pending_board_events })
     | Keeper_failure_judgment_contract.Escalate_to_operator { rationale } ->
       let rationale = Keeper_internal_error.cap_blocker_detail rationale in
       record_failure_judgment_outcome
         ~keeper_name
         request
         (Keeper_failure_judgment_contract.decision_label verdict);
       Log.Keeper.warn
         "%s: independent failure judgment requires operator \
          judge_runtime=%s class=%s provenance=%s rationale=%s"
         keeper_name
         judge_runtime_id
         (Keeper_runtime_failure_route.judgment_class_label request.fj_judgment)
         (Keeper_runtime_failure_route.judgment_provenance_label
            request.fj_provenance)
         rationale;
       `Settle (Judgment_operator_required { judge_runtime_id; rationale }))
;;

(* Body of [run_keeper_cycle], runnable only while holding the keeper's
   turn slot ([Keeper_turn_admission]). The post-failure meta re-reads stay
   inside the slot for the same reason as the chat lane: a concurrent turn
   must not interleave with this lane's meta writes (RFC-0225 §1). *)
let run_keeper_cycle_admitted
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(wake : Keeper_registry.wake_reason)
      ?failure_judgment
      ()
  =
  let admitted_execution =
    In_turn_pulse.with_in_turn_liveness_pulse ~ctx ~meta:meta_after_triage ~stop (fun () ->
      let prepared =
        match failure_judgment with
        | None -> `Run obs
        | Some request ->
          prepare_failure_judgment_turn
            ~base_path:ctx.config.base_path
            ~keeper_name:meta_after_triage.name
            ~request
            obs
      in
      match prepared with
      | `Settle outcome -> `Judgment outcome
      | `Run observation ->
        `Turn
          (Keeper_unified_turn.run_keeper_cycle
             ~config:ctx.config
             ~meta:meta_after_triage
             ~observation
             ~generation:meta_after_triage.runtime.generation
             ~wake
             ~channel:turn_decision.channel
             ?hitl_resolution
             ?continuation_delivery_channel
             (* RFC-0315: pass the whole decision, not just its channel — the
                prompt renders the verdict reasons so the turn knows why it woke. *)
             ~turn_decision
             ~shared_context
             ?event_bus
             ()))
  in
  match admitted_execution with
  | `Judgment outcome -> Judgment_settled { meta = meta_after_triage; outcome }
  | `Turn (Error failure) ->
    let err = failure.Keeper_unified_turn.error in
    let e_str = Agent_sdk.Error.to_string err in
    Log.Keeper.debug "%s: keeper cycle failed: %s" meta_after_triage.name e_str;
    (* Classify on the typed [Config (InvalidConfig { field = "eio_context" })]
       tag via [Runtime_oas_runner.is_eio_context_error], not by substring-
       scanning [e_str]: an Eio wording change must not silently drop this
       fatal-environment promotion. [e_str] is kept for the log/failure-reason
       message only. *)
    if Runtime_oas_runner.is_eio_context_error err then (
      Log.Keeper.error
        "%s: fatal environment error — promoting to Keeper_fiber_crash: %s"
        meta_after_triage.name
        e_str;
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string HeartbeatFailures)
        ~labels:[ "keeper", meta_after_triage.name; "phase", "fatal_environment" ]
        ();
      Keeper_registry.set_failure_reason
        ~base_path:ctx.config.base_path
        meta_after_triage.name
        (Some
           (Keeper_registry.Exception (Printf.sprintf "fatal environment error: %s" e_str)));
      raise Keeper_registry.Keeper_fiber_crash);
    if Observations.is_provider_timeout_error err
    then (
      let keeper_name = meta_after_triage.name in
      Keeper_turn_holders.reset_budget_exhaustion ~keeper_name;
      Log.Keeper.warn
        "%s: provider_timeout observed; preserving original turn \
         failure without Provider_timeout_loop latch"
        keeper_name);
    let meta =
      match read_effective_meta ctx.config meta_after_triage.name with
      | Ok (Some latest) -> latest
      | Ok None ->
        Log.Keeper.error
          "keeper:%s read_effective_meta returned None after turn failure, using stale meta"
          meta_after_triage.name;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string MetaReadFailures)
          ~labels:
            [ "keeper", meta_after_triage.name; "site", "none_after_failure" ]
          ();
        meta_after_triage
      | Error e ->
        Log.Keeper.error
          "keeper:%s read_effective_meta failed after turn failure (%s), using stale meta"
          meta_after_triage.name
          e;
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string MetaReadFailures)
          ~labels:
            [ "keeper", meta_after_triage.name; "site", "error_after_failure" ]
          ();
        meta_after_triage
    in
    Failed { meta; failure }
  | `Turn (Ok (Keeper_unified_turn.Turn_completed updated)) ->
    Keeper_turn_holders.reset_budget_exhaustion ~keeper_name:meta_after_triage.name;
    Observations.clear_provider_timeout_failure_reason
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name;
    Completed updated
  | `Turn (Ok (Keeper_unified_turn.Turn_cancelled meta)) -> Cancelled meta
  | `Turn (Ok (Keeper_unified_turn.Turn_skipped meta)) -> Skipped meta
;;

let run_keeper_cycle
      ?event_bus
      ?hitl_resolution
      ?continuation_delivery_channel
      ~ctx
      ~meta_after_triage
      ~stop
      ~obs
      ~(turn_decision : Keeper_world_observation.keeper_cycle_decision)
      ~shared_context
      ~(wake : Keeper_registry.wake_reason)
      ?failure_judgment
      ()
  =
  match
    Keeper_turn_admission.run_if_free
      ~base_path:ctx.config.base_path
      ~keeper_name:meta_after_triage.name
      (run_keeper_cycle_admitted
         ~ctx
         ~meta_after_triage
         ~stop
         ~obs
         ~turn_decision
         ~shared_context
         ~wake
         ?failure_judgment
         ?event_bus
         ?hitl_resolution
         ?continuation_delivery_channel)
  with
  | `Ran outcome -> outcome
  | `Busy ((Keeper_turn_admission.Shutdown_requested operation_id) as block) ->
    Log.Keeper.info
      "%s: autonomous turn admission closed by shutdown operation %s"
      meta_after_triage.name
      (Keeper_shutdown_types.Operation_id.to_string operation_id);
    Busy { meta = meta_after_triage; block }
  | `Busy ((Keeper_turn_admission.Turn_busy in_flight) as block) ->
    (* Another lane holds this keeper's turn slot (RFC-0225 §3.1): skip the
       cycle and return the pre-cycle meta unchanged. The next heartbeat
       retries naturally — same shape as the pre-existing skip decisions. *)
    let holder =
      match in_flight with
      | Some { Keeper_turn_admission.lane; started_at } ->
        (* NDT-OK: gettimeofday renders the in-flight turn age for the log line only *)
        Printf.sprintf
          "%s turn running for %.0fs"
          (Keeper_turn_admission.lane_to_string lane)
          (Unix.gettimeofday () -. started_at)
      | None -> "holder info not yet published"
    in
    Log.Keeper.info
      "%s: turn slot busy (%s); skipping autonomous cycle until next heartbeat"
      meta_after_triage.name
      holder;
    Busy { meta = meta_after_triage; block }
;;
