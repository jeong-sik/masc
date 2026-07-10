(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   provider timeout resolution, context overflow observation, keeper pause/resume
   sync, partial-commit continue gate, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify
module StringMap = Set_util.StringMap
let ( let* ) = Result.bind

exception Partial_commit_gate_sync_failed of string
exception Partial_commit_gate_edit_unsupported

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : Keeper_context_runtime.max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int;
}

let next_fail_open_runtime_for_turn =
  Keeper_turn_runtime_budget_routing.next_fail_open_runtime_for_turn

let sdk_error_kind = Keeper_turn_runtime_budget_routing.sdk_error_kind
include Keeper_turn_runtime_budget_provider_timeout

(* PR #13120 review: declared in [Env_config_keeper.KeeperRetryBackoff]
   so the env knob catalog generator at [bin/env_knob_catalog.ml]
   picks it up — that generator only scans [lib/config/env_config_*.ml],
   so a knob declared here would silently drift from
   [docs/runtime-tunables.md] and from [env_config_snapshot]. *)
let degraded_retry_slot_phase_budget_sec =
  Env_config_keeper.KeeperRetryBackoff.degraded_retry_slot_phase_budget_sec
;;

let degraded_retry_slot_phase_available ~(time_spent_in_turn_s : float) : bool =
  Float.max 0.0 time_spent_in_turn_s < degraded_retry_slot_phase_budget_sec

let runtime_reason_is_structural_attempt_timeout
    (reason : Keeper_turn_driver.runtime_exhaustion_reason) : bool =
  (* Typed match only. Producers must construct [Structural_attempt_timeout]
     explicitly; free-form OAS-ceiling-looking text remains [Other_detail].
     Enumerate every constructor so a new reason variant fails to compile here
     rather than silently falling through to [false]. *)
  match reason with
  | Keeper_turn_driver.Structural_attempt_timeout _ -> true
  | Keeper_turn_driver.Connection_refused
  | Keeper_turn_driver.Dns_failure
  | Keeper_turn_driver.No_providers_available
  | Keeper_turn_driver.All_providers_failed
  | Keeper_turn_driver.Candidates_filtered_after_cycles
  | Keeper_turn_driver.Max_turns_exceeded
  | Keeper_turn_driver.Capacity_exhausted
  | Keeper_turn_driver.Other_detail _ -> false

let degraded_retry_bypasses_slot_phase_guard
    (err : Agent_sdk.Error.sdk_error) : bool =
  (* Enumerate every [masc_internal_error] variant plus [None] so the
     compiler flags any new constructor here. The old [_ -> false] silently
     extended the "not a budget exhaustion" set whenever a new error class
     was added to Runtime_error_classify, which is exactly the wrong default
     for a guard that decides whether to bypass slot-phase admission. *)
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Provider_timeout _) -> true
  | Some (Keeper_turn_driver.Runtime_exhausted { reason = Keeper_turn_driver.Structural_attempt_timeout _; _ }) ->
      true
  | Some
      ( Keeper_turn_driver.Runtime_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _

      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _
      (* RFC-0159 Phase A: Internal_* variants are not OAS-budget timeouts. *)
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    false

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

type 'a degraded_retry_prepare_result =
  | Degraded_retry_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }
  | Degraded_retry_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_sdk.Error.sdk_error;
    }

type 'a degraded_retry_step =
  | Degraded_retry_step_not_allowed
  | Degraded_retry_step_slot_phase_exhausted of {
      retry : EC.degraded_retry;
      reason : string;
    }
  | Degraded_retry_step_setup_failed of {
      retry : EC.degraded_retry;
      reason : string;
      fail_open_err : Agent_sdk.Error.sdk_error;
    }
  | Degraded_retry_step_prepared of {
      retry : EC.degraded_retry;
      reason : string;
      next : 'a;
    }

let empty_degraded_retry_runtime_error =
  Agent_sdk.Error.Internal "degraded retry selected empty next_runtime"

let prepare_degraded_retry_allowed
      ~current_runtime_id
      ~attempt
      ~err
      ~(retry : EC.degraded_retry)
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime
  =
  let reason = EC.degraded_retry_reason_to_string retry.fallback_reason in
  match String.trim retry.next_runtime with
  | "" ->
    publish_cascade_resolution
      ~runtime_id:current_runtime_id
      ~decision:Keeper_unified_turn_cascade_resolution.No_degraded_retry
      ~reason:"empty_degraded_retry_runtime"
      ~next_runtime:None
      ~attempt
      err;
    Degraded_retry_setup_failed {
      retry;
      reason;
      fail_open_err = empty_degraded_retry_runtime_error;
    }
  | next_runtime ->
    let retry = { retry with next_runtime } in
    publish_cascade_resolution
      ~runtime_id:current_runtime_id
      ~decision:Keeper_unified_turn_cascade_resolution.Degraded_retry_allowed
      ~reason
      ~next_runtime:(Some retry.next_runtime)
      ~attempt
      err;
    (match setup_runtime retry.next_runtime with
     | Ok next ->
       emit_runtime_selected ~runtime_id:retry.next_runtime ~fallback_reason:reason;
       emit_runtime_rotation
         ~from_runtime:current_runtime_id
         ~to_runtime:retry.next_runtime
         ~reason;
       Degraded_retry_prepared { retry; reason; next }
     | Error fail_open_err ->
       Degraded_retry_setup_failed { retry; reason; fail_open_err })

let next_fail_open_runtime_for_turn_with_budget
    ~(base_runtime : string)
    ~(effective_runtime : string)
    ~(attempted_runtimes : string list)
    ~(estimated_input_tokens : int)
    ?time_spent_in_turn_s
    ~(remaining_turn_budget_s : float)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry_budget_decision =
  match
    next_fail_open_runtime_for_turn
      ~base_runtime ~effective_runtime
      ~attempted_runtimes err
  with
  | None -> No_degraded_retry
  | Some retry ->
      let first_contract_rotation = false in
      if
        match time_spent_in_turn_s with
        | Some time_spent_in_turn_s ->
            (not (degraded_retry_slot_phase_available ~time_spent_in_turn_s))
            && not (degraded_retry_bypasses_slot_phase_guard err)
            && not first_contract_rotation
        | None -> false
      then Degraded_retry_slot_phase_exhausted retry
      else (
        let _ = estimated_input_tokens in
        let _ = remaining_turn_budget_s in
        Degraded_retry_allowed retry)

let plan_degraded_retry_step
      ~base_runtime
      ~current_runtime_id
      ~attempted_runtimes
      ~estimated_input_tokens
      ~time_spent_in_turn_s
      ~remaining_turn_budget_s
      ~attempt
      ~err
      ~allow_retry
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime
  =
  match
    next_fail_open_runtime_for_turn_with_budget
      ~base_runtime
      ~effective_runtime:current_runtime_id
      ~attempted_runtimes
      ~estimated_input_tokens
      ?time_spent_in_turn_s
      ~remaining_turn_budget_s
      err
  with
  | No_degraded_retry -> Degraded_retry_step_not_allowed
  | Degraded_retry_allowed retry when allow_retry retry ->
    (match
       prepare_degraded_retry_allowed
         ~current_runtime_id
         ~attempt
         ~err
         ~retry
         ~publish_cascade_resolution
         ~emit_runtime_selected
         ~emit_runtime_rotation
         ~setup_runtime
     with
     | Degraded_retry_prepared { retry; reason; next } ->
       Degraded_retry_step_prepared { retry; reason; next }
     | Degraded_retry_setup_failed { retry; reason; fail_open_err } ->
       Degraded_retry_step_setup_failed { retry; reason; fail_open_err })
  | Degraded_retry_allowed _ -> Degraded_retry_step_not_allowed
  | Degraded_retry_slot_phase_exhausted retry when allow_retry retry ->
    let reason = EC.degraded_retry_reason_to_string retry.fallback_reason in
    publish_cascade_resolution
      ~runtime_id:current_runtime_id
      ~decision:Keeper_unified_turn_cascade_resolution.Degraded_retry_slot_phase_exhausted
      ~reason
      ~next_runtime:(Some retry.next_runtime)
      ~attempt
      err;
    Degraded_retry_step_slot_phase_exhausted { retry; reason }
  | Degraded_retry_slot_phase_exhausted _ -> Degraded_retry_step_not_allowed

let yield_before_direct_no_progress_retry () = Eio.Fiber.yield ()

let direct_no_progress_retry_reason err =
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some internal_error ->
    (match Keeper_turn_driver.accept_no_progress_retry_kind internal_error with
     | Some `Empty_no_progress -> Some EC.Empty_no_progress
     | Some `Thinking_only_no_progress -> Some EC.Thinking_only_no_progress
     | Some `Read_only_no_progress | None -> None)
  | None -> None

let retry_reason_is_direct_no_progress (retry : EC.degraded_retry) =
  match retry.fallback_reason with
  | EC.Empty_no_progress | EC.Thinking_only_no_progress -> true
  | _ -> false

let direct_no_progress_retry_decision
    ~base_runtime
    ~effective_runtime
    ~attempted_runtimes
    ~estimated_input_tokens
    ?time_spent_in_turn_s
    ~remaining_turn_budget_s
    err =
  match direct_no_progress_retry_reason err with
  | None -> No_degraded_retry
  | Some (EC.Empty_no_progress | EC.Thinking_only_no_progress) ->
    (match
       next_fail_open_runtime_for_turn_with_budget
         ~base_runtime
         ~effective_runtime
         ~attempted_runtimes
         ~estimated_input_tokens
         ?time_spent_in_turn_s
         ~remaining_turn_budget_s
         err
     with
     | Degraded_retry_allowed retry when retry_reason_is_direct_no_progress retry
       -> Degraded_retry_allowed retry
     | Degraded_retry_slot_phase_exhausted retry
       when retry_reason_is_direct_no_progress retry ->
       Degraded_retry_slot_phase_exhausted retry
     | _ -> No_degraded_retry)
  | Some _ -> No_degraded_retry

let run_direct_no_progress_retry_loop
      ~keeper_name
      ~base_runtime
      ~initial_runtime
      ~initial_max_context
      ~estimated_input_tokens
      ~timeout_sec
      ~remaining_turn_budget_s
      ~current_turn_phase_elapsed_ms
      ~now_s
      ~(setup_retry_runtime :
         string -> (runtime_execution, Agent_sdk.Error.sdk_error) result)
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~record_retry_setup_failure
      ~before_retry
      ~run_once
      ()
  =
  let rec run_attempt
      ~runtime_id
      ?runtime_execution
      ~attempted_runtimes
      ?degraded_retry
      ~runtime_rotation_attempts
      ~attempt
      ~retry_phase_started_at
      ~is_retry
      ()
    =
    let degraded_retry_runtime =
      Option.map (fun (retry : EC.degraded_retry) -> retry.next_runtime)
        degraded_retry
    in
    let fallback_reason =
      Option.map (fun (retry : EC.degraded_retry) -> retry.fallback_reason)
        degraded_retry
    in
    let attempt_max_context =
      match runtime_execution with
      | Some execution -> execution.max_context
      | None -> initial_max_context
    in
    match
      run_once
        ~runtime_id
        ~max_context:attempt_max_context
        ~is_retry
        ~degraded_retry_runtime
        ~fallback_reason
        ~runtime_rotation_attempts:(List.rev runtime_rotation_attempts)
    with
    | Ok result -> Ok (result, attempt_max_context)
    | Error err as error ->
      (match
         plan_degraded_retry_step
           ~base_runtime
           ~current_runtime_id:runtime_id
           ~attempted_runtimes
           ~estimated_input_tokens
           ~time_spent_in_turn_s:
             (Some (timeout_sec -. remaining_turn_budget_s ()))
           ~remaining_turn_budget_s:(remaining_turn_budget_s ())
           ~attempt
           ~err
           ~allow_retry:retry_reason_is_direct_no_progress
           ~publish_cascade_resolution
           ~emit_runtime_selected
           ~emit_runtime_rotation
           ~setup_runtime:setup_retry_runtime
       with
       | Degraded_retry_step_not_allowed ->
         let reason =
           match direct_no_progress_retry_reason err with
           | Some retry_reason ->
             Printf.sprintf
               "terminal_%s_no_degraded_retry"
               (EC.degraded_retry_reason_to_string retry_reason)
           | None -> "terminal_error_not_degraded_retry_eligible"
         in
         publish_cascade_resolution
           ~runtime_id
           ~decision:Keeper_unified_turn_cascade_resolution.No_degraded_retry
           ~reason
           ~next_runtime:None
           ~attempt
           err;
         error
       | Degraded_retry_step_slot_phase_exhausted { retry; reason } ->
         Log.Keeper.warn
           "%s: direct keeper_msg no-progress response from runtime=%s suggested \
            retry to %s (reason=%s), but productive slot phase budget %.1fs \
            is exhausted after %.1fs"
           keeper_name
           runtime_id
           retry.next_runtime
           reason
           degraded_retry_slot_phase_budget_sec
           (timeout_sec -. remaining_turn_budget_s ());
         error
       | Degraded_retry_step_setup_failed { retry; fail_open_err; _ } ->
         let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
           current_turn_phase_elapsed_ms retry_phase_started_at
         in
         let rotation_attempt =
           Keeper_unified_turn_rotation_attempt.build
             ~recorded_at:(now_iso ())
             ~productive_phase_elapsed_ms
             ?retry_phase_elapsed_ms
             ~from_runtime:runtime_id
             ~retry
             ~outcome:Keeper_execution_receipt.Rotation_setup_failed
             fail_open_err
         in
         record_retry_setup_failure
           ~from_runtime:runtime_id
           ~retry
           ~rotation_attempt
           ~fail_open_err;
         Error fail_open_err
       | Degraded_retry_step_prepared { retry; reason; next = next_execution }
         ->
         let retry_phase_started_at =
           match retry_phase_started_at with
           | Some _ -> retry_phase_started_at
           | None -> Some (now_s ())
         in
         let productive_phase_elapsed_ms, retry_phase_elapsed_ms =
           current_turn_phase_elapsed_ms retry_phase_started_at
         in
         let rotation_attempt =
           Keeper_unified_turn_rotation_attempt.build
             ~recorded_at:(now_iso ())
             ~productive_phase_elapsed_ms
             ?retry_phase_elapsed_ms
             ~from_runtime:runtime_id
             ~retry
             ~outcome:Keeper_execution_receipt.Rotation_retry_scheduled
             err
         in
         let retry_resolution = next_execution.max_context_resolution in
         Log.Keeper.warn
           "%s: direct keeper_msg no-progress response from runtime=%s; retrying \
            runtime=%s reason=%s max_context=%d context_budget=%d \
            primary_budget=%d requested_override=%s"
           keeper_name
           runtime_id
           next_execution.runtime_id
           reason
           next_execution.max_context
           retry_resolution.effective_budget
           retry_resolution.primary_budget
           (match retry_resolution.requested_override with
            | Some requested -> string_of_int requested
            | None -> "none");
         before_retry ();
         run_attempt
           ~runtime_id:next_execution.runtime_id
           ~runtime_execution:next_execution
           ~attempted_runtimes:(next_execution.runtime_id :: attempted_runtimes)
           ~degraded_retry:retry
           ~runtime_rotation_attempts:(rotation_attempt :: runtime_rotation_attempts)
           ~attempt:1
           ~retry_phase_started_at
           ~is_retry:true
           ())
  in
  run_attempt
    ~runtime_id:initial_runtime
    ~attempted_runtimes:[ initial_runtime ]
    ~runtime_rotation_attempts:[]
    ~attempt:1
    ~retry_phase_started_at:None
    ~is_retry:false
    ()

type turn_event_bus_overflow =
  Keeper_turn_runtime_budget_event_bus.turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_compaction =
  Keeper_turn_runtime_budget_event_bus.turn_event_bus_compaction = {
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;
  phase_hint : string;
}

type turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.turn_event_bus_summary = {
  correlation_id : string option;
  run_id : string option;
  caused_by : string option;
  event_count : int;
  payload_kinds : string list;
  overflow_imminent : turn_event_bus_overflow option;
  context_compact_started_count : int;
  context_compacted_count : int;
  last_compaction : turn_event_bus_compaction option;
}

let empty_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.empty_turn_event_bus_summary

let merge_turn_event_bus_summary =
  Keeper_turn_runtime_budget_event_bus.merge_turn_event_bus_summary

let add_payload_kind =
  Keeper_turn_runtime_budget_event_bus.add_payload_kind

let summarize_turn_event_bus
    (events : Agent_sdk.Event_bus.event list) : turn_event_bus_summary =
  List.fold_left
    (fun acc (evt : Agent_sdk.Event_bus.event) ->
      let correlation_id =
        match acc.correlation_id with
        | Some _ -> acc.correlation_id
        | None -> Some evt.meta.correlation_id
      in
      let run_id =
        match acc.run_id with
        | Some _ -> acc.run_id
        | None -> Some evt.meta.run_id
      in
      let caused_by =
        match acc.caused_by with
        | Some _ -> acc.caused_by
        | None -> evt.meta.caused_by
      in
      let acc =
        { acc with
          correlation_id;
          run_id;
          caused_by;
          event_count = acc.event_count + 1;
          payload_kinds =
            add_payload_kind acc.payload_kinds
              (Agent_sdk.Event_bus.payload_kind evt.payload);
        }
      in
      match evt.payload with
      | Agent_sdk.Event_bus.ContextOverflowImminent
          { estimated_tokens; limit_tokens; _ } ->
          {
            acc with
            overflow_imminent =
              Some { estimated_tokens; limit_tokens };
          }
      | Agent_sdk.Event_bus.ContextCompactStarted _ ->
          {
            acc with
            context_compact_started_count =
              acc.context_compact_started_count + 1;
          }
      | Agent_sdk.Event_bus.ContextCompacted
          { before_tokens; after_tokens; phase; _ } ->
          {
            acc with
            context_compacted_count = acc.context_compacted_count + 1;
            last_compaction =
              Some
                {
                  before_tokens;
                  after_tokens;
                  tokens_freed = max 0 (before_tokens - after_tokens);
                  phase_hint = phase;
                };
          }
      | _ -> acc)
    empty_turn_event_bus_summary
    events

let turn_event_bus_overflow_evidence_detail
    (summary : turn_event_bus_summary) : string =
  let option_int = function
    | Some value -> string_of_int value
    | None -> "none"
  in
  let overflow_estimated_tokens, overflow_limit_tokens =
    match summary.overflow_imminent with
    | Some overflow ->
      Some overflow.estimated_tokens, Some overflow.limit_tokens
    | None -> None, None
  in
  let last_compaction_detail =
    match summary.last_compaction with
    | None -> "last_compaction=none"
    | Some compaction ->
      Printf.sprintf
        "last_compaction_before_tokens=%d,last_compaction_after_tokens=%d,\
         last_compaction_tokens_freed=%d,last_compaction_phase=%s"
        compaction.before_tokens
        compaction.after_tokens
        compaction.tokens_freed
        compaction.phase_hint
  in
  Printf.sprintf
    "oas_retry_evidence(events=%d,payload_kinds=[%s],\
     context_compact_started=%d,context_compacted=%d,%s,\
     overflow_estimated_tokens=%s,overflow_limit_tokens=%s)"
    summary.event_count
    (String.concat "," summary.payload_kinds)
    summary.context_compact_started_count
    summary.context_compacted_count
    last_compaction_detail
    (option_int overflow_estimated_tokens)
    (option_int overflow_limit_tokens)

let context_overflow_event_of_error
    ~(fallback_tokens : int)
    ?(turn_event_bus : turn_event_bus_summary =
      empty_turn_event_bus_summary)
    (err : Agent_sdk.Error.sdk_error) : Keeper_state_machine.event =
  match turn_event_bus.overflow_imminent with
  | Some { estimated_tokens; limit_tokens } ->
      Keeper_state_machine.Context_overflow_detected
        {
          source = `Oas_signal;
          token_count = max 0 estimated_tokens;
          limit_tokens = Some limit_tokens;
        }
  | None ->
      match err with
      | Agent_sdk.Error.Api (ContextOverflow { limit; _ }) ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Prompt_rejected;
              token_count = Option.value ~default:(max 0 fallback_tokens) limit;
              limit_tokens = limit;
            }
      | _ ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Oas_signal;
              token_count = max 0 fallback_tokens;
              limit_tokens = None;
            }

let pause_resume_policy_of_circuit_effect = function
  | Keeper_failure_policy.Operator_breaker ->
    Keeper_supervisor_pause_policy.Manual_resume_required
  | Keeper_failure_policy.Skip_circuit
  | Keeper_failure_policy.Count_for_circuit
  | Keeper_failure_policy.Provider_cooldown ->
    Keeper_supervisor_pause_policy.Auto_resume_with_backoff
;;

let overflow_pause_resume_policy () =
  (Keeper_failure_policy.decide Keeper_failure_policy.Turn_overflow_pause)
    .circuit_effect
  |> pause_resume_policy_of_circuit_effect
;;

let pause_keeper_for_overflow
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(reason : string) : keeper_meta =
  if Keeper_pacing_shadow.pacing_enforced ()
  then (
    (* RFC-0313 W3: unresolved context overflow no longer pauses. The caller
       fails the turn with the ContextOverflow error, so the routing site in
       [Keeper_unified_turn] records pacing and enqueues a [Context_overflow]
       judgment stimulus. Only the failure reason is latched here as
       evidence. *)
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some Keeper_registry.Turn_overflow_pause);
    Log.Keeper.warn
      "%s: unresolved context overflow (%s) recorded without pause \
       (RFC-0313 W3); judgment stimulus follows from turn failure routing"
      meta.name
      reason;
    meta)
  else (
  let resume_policy = overflow_pause_resume_policy () in
  match
    Keeper_supervisor_pause_policy.handle_auto_pause_from_meta
      ~config
      ~meta
      ~reason_tag:"overflow"
      ~lifecycle_detail:(Printf.sprintf "context_overflow %s" reason)
      ~log_message:(Printf.sprintf "keeper paused after unresolved context overflow (%s)" reason)
      ~blocker_class:(Some Sdk_token_budget_exceeded)
      ~resume_policy
      ()
  with
  | Ok paused_meta ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string FailureDrivenPause)
      ~labels:[ "keeper", meta.name; "site", "turn_overflow" ]
      ();
    (* Issue #8581: latch the retry-exhausted condition BEFORE the
       Operator_pause that drives the Paused phase.  The SSOT
       function already dispatched [Operator_pause]; we only need
       the extra [Compact_retry_exhausted] signal here. *)
    dispatch_keeper_phase_event
      ~config
      ~keeper_name:meta.name
      Keeper_state_machine.Compact_retry_exhausted;
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some Keeper_registry.Turn_overflow_pause);
    paused_meta
  | Error _err ->
    (* Fallback: write failed but we must not leave the caller with
       an unpaused keeper.  Replicate the old in-memory pause path
       (registry update + events) so the scheduling loop skips this
       keeper on the next tick.  The write failure is already logged
       and counted by [handle_auto_pause_from_meta]. *)
    let paused_meta =
      { meta with
        paused = true;
        auto_resume_after_sec =
          Keeper_supervisor_pause_policy.auto_resume_after_sec_for_policy
            meta
            resume_policy;
        updated_at = now_iso ();
      }
    in
    Keeper_registry.update_meta ~base_path:config.base_path meta.name paused_meta;
    Keeper_registry.set_failure_reason
      ~base_path:config.base_path
      meta.name
      (Some Keeper_registry.Turn_overflow_pause);
    dispatch_keeper_phase_event
      ~config
      ~keeper_name:meta.name
      Keeper_state_machine.Compact_retry_exhausted;
    dispatch_keeper_phase_event
      ~config
      ~keeper_name:meta.name
      Keeper_state_machine.Operator_pause;
    paused_meta)

let wake_resumed_keeper_fiber ~(config : Workspace.config) ~keeper_name () =
  match Keeper_registry.get ~base_path:config.base_path keeper_name with
  | Some entry ->
    (* tla-lint: allow-mutation: keeper resume signal after durable state commit *)
    Atomic.set entry.fiber_wakeup true
  | None ->
    Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
      ~config
      ~keeper_name
      ~side_effect:"resume sync fiber wakeup"
      "registry entry missing after metadata update"
;;

let sync_keeper_paused_state_impl
    ~wake_after_resume
    ~(resume_policy : Keeper_supervisor_pause_policy.crash_pause_resume_policy option)
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(paused : bool) : (keeper_meta, string) result =
  let auto_resume_after_sec =
    match paused, resume_policy with
    | true, Some policy ->
      Keeper_supervisor_pause_policy.auto_resume_after_sec_for_policy meta policy
    | true, None -> meta.auto_resume_after_sec
    | false, _ -> None
  in
  let synced_meta =
    let base = { meta with paused; auto_resume_after_sec; updated_at = now_iso () } in
    if paused
    then base
    else
      { base with
        latched_reason = None
      ; runtime = { base.runtime with last_blocker = None }
      }
  in
  (* #9733: pause/resume sync is operator-driven; the [paused]
     field is cycle-owned at this site, so use the same merged-CAS
     write as overflow pause + unified-turn failure paths.  Without
     this, an operator pause/resume that races a heartbeat tick
     can land partially (paused field correct on disk, but write
     reports failure) which leaves the registry update unsync'd
     with disk. *)
  match
    write_meta_with_merge_returning
         ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
         config
         synced_meta
  with
  | Error err ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string WriteMetaFailures)
        ~labels:[("keeper", meta.name);
                 ("phase",
                  if paused then "pause_sync" else "resume_sync")]
        ();
      Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync write_meta"
                        (if paused then "pause" else "resume"))
        ~severity:`Error
        err;
    Error (Printf.sprintf "failed to write meta: %s" err)
  | Ok persisted_meta ->
    (* The merge may preserve a newer, distinct operator pause. Project the
       exact persisted version into the registry; the version-gated CAS also
       participates in registration, closing stale-entry installation races. *)
    Keeper_registry.sync_persisted_meta_if_newer
      ~base_path:config.base_path
      meta.name
      persisted_meta;
    if paused
    then
      (match
            Keeper_supervisor_pause_policy.release_owned_active_tasks_after_typed_pause
              ~config
              ~meta:persisted_meta
              ~reason_tag:"pause_sync"
          with
          | Ok released_meta -> Ok released_meta
          | Error err ->
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RuntimeSyncFailures)
              ~labels:[ "keeper", meta.name; "site", "pause_sync_task_release" ]
              ();
            Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
              ~config
              ~keeper_name:meta.name
              ~side_effect:"pause sync task release"
              ~severity:`Error
              err;
            Error ("failed to release paused keeper tasks: " ^ err))
    else (
      if wake_after_resume && not persisted_meta.paused
      then wake_resumed_keeper_fiber ~config ~keeper_name:meta.name ();
      Ok persisted_meta)

let sync_keeper_paused_state ~(config : Workspace.config) ~(meta : keeper_meta) ~paused
  =
  sync_keeper_paused_state_impl
    ~wake_after_resume:true
    ~resume_policy:None
    ~config
    ~meta
    ~paused

let sync_keeper_paused_state_with_resume_policy
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(paused : bool)
    ~(resume_policy : Keeper_supervisor_pause_policy.crash_pause_resume_policy)
  : (keeper_meta, string) result
  =
  sync_keeper_paused_state_impl
    ~wake_after_resume:true
    ~resume_policy:(Some resume_policy)
    ~config
    ~meta
    ~paused

let current_keeper_meta ~(config : Workspace.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

type post_turn_resilience_handles = {
  resilience_audit_store : Shared_audit.Store.t option;
  resilience_strategy_executor : Resilience.Recovery.strategy_executor option;
  sync_lifecycle_meta : post_turn_lifecycle -> post_turn_lifecycle;
}

let resilience_audit_dir
    ~(config : Workspace.config)
    ~(keeper_name : string) : string =
  let masc_root =
    Common.masc_dir_from_base_path ~base_path:config.base_path
  in
  Filename.concat
    (Filename.concat masc_root "resilience_audit")
    (Workspace_utils.safe_filename keeper_name)

let short_resilience_detail detail =
  let detail = String.trim detail in
  if String.length detail <= 240 then detail
  else String.sub detail 0 240 ^ "..."

let resilience_execution_event_to_string = function
  | Resilience.Recovery.RetryAttempt { attempt; max_attempts } ->
      Printf.sprintf "retry_attempt(%d/%d)" attempt max_attempts
  | Resilience.Recovery.RetryBackoff { attempt; delay_s; error } ->
      Printf.sprintf "retry_backoff(attempt=%d,delay_s=%.3f,error=%s)"
        attempt delay_s (short_resilience_detail error)
  | Resilience.Recovery.FallbackApply { value; confidence_delta } ->
      Printf.sprintf "fallback_apply(value=%s,confidence_delta=%.3f)"
        (short_resilience_detail value) confidence_delta
  | Resilience.Recovery.HandoffRequest { message; preserve_state } ->
      Printf.sprintf "handoff_request(preserve_state=%b,message=%s)"
        preserve_state (short_resilience_detail message)
  | Resilience.Recovery.AbortRun { reason } ->
      Printf.sprintf "abort_run(reason=%s)"
        (short_resilience_detail reason)

let make_post_turn_resilience_executor
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(on_paused : keeper_meta -> unit)
  : Resilience.Recovery.strategy_executor =
  let pause_for_operator ~code ~detail =
    let detail = short_resilience_detail detail in
    let latest_meta = current_keeper_meta ~config ~fallback_meta:meta in
    Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name
      (Some
         (Keeper_registry.Provider_runtime_error
            { code; detail; provider_id = None; http_status = None
            ; runtime_id = None
            ; reason = None
            }));
    if Keeper_pacing_shadow.pacing_enforced ()
    then (
      (* RFC-0313 W3: post-turn resilience strategies latch the failure
         reason as evidence but no longer pause. The failed turn already
         went through failure routing (pacing + judgment stimulus). *)
      Log.Keeper.warn ~keeper_name:meta.name
        "%s: post-turn resilience strategy (code=%s) recorded without pause \
         (RFC-0313 W3): %s"
        meta.name code detail;
      Ok ())
    else
      match
        sync_keeper_paused_state_with_resume_policy
          ~config
          ~meta:latest_meta
          ~paused:true
          ~resume_policy:Keeper_supervisor_pause_policy.Auto_resume_with_backoff
      with
      | Ok paused_meta ->
          Otel_metric_store.inc_counter
            Keeper_metrics.(to_string FailureDrivenPause)
            ~labels:[ "keeper", meta.name; "site", "post_turn_resilience" ]
            ();
          on_paused paused_meta;
          Ok ()
      | Error err -> Error err
  in
  let fail_and_pause ~code ~detail =
    let detail = short_resilience_detail detail in
    match pause_for_operator ~code ~detail with
    | Ok () -> detail
    | Error err -> Printf.sprintf "%s (pause failed: %s)" detail err
  in
  {
    Resilience.Recovery.run_retry_attempt =
      (fun ~attempt ->
        let detail =
          Printf.sprintf
            "post-turn resilience retry attempt %d has no operation-specific \
             retry callback; paused for operator recovery"
            attempt
        in
        Resilience.Recovery.Fatal_failure
          (fail_and_pause ~code:"resilience_retry_unbound" ~detail));
    sleep =
      (fun delay_s ->
        if delay_s > 0.0 then
          match Eio_context.get_clock_opt () with
          | Some clock -> Eio.Time.sleep clock delay_s
          | None -> ());
    on_event =
      (fun event ->
        Log.Keeper.warn ~keeper_name:meta.name "post-turn resilience event: %s"
          (resilience_execution_event_to_string event));
    apply_fallback =
      (fun ~value ~confidence_delta ->
        let detail =
          Printf.sprintf
            "post-turn resilience fallback has no typed target \
             (value=%s confidence_delta=%.3f); paused for operator recovery"
            (short_resilience_detail value) confidence_delta
        in
        Error
          (fail_and_pause ~code:"resilience_fallback_unbound" ~detail));
    request_handoff =
      (fun ~message ~preserve_state ->
        let detail =
          Printf.sprintf
            "post-turn resilience handoff requested preserve_state=%b: %s"
            preserve_state message
        in
        pause_for_operator ~code:"resilience_handoff" ~detail);
    abort =
      (fun ~reason ->
        let detail =
          Printf.sprintf
            "post-turn resilience abort requested: %s"
            reason
        in
        pause_for_operator ~code:"resilience_abort" ~detail);
  }

let post_turn_resilience_handles
    ~(config : Workspace.config)
    ~(meta : keeper_meta) : post_turn_resilience_handles =
  let paused_meta = Atomic.make None in
  let sync_lifecycle_meta lifecycle =
    match Atomic.get paused_meta with
    | None -> lifecycle
    | Some paused ->
        { lifecycle with
          updated_meta =
            { lifecycle.updated_meta with
              paused = paused.paused;
              updated_at = paused.updated_at;
              auto_resume_after_sec = paused.auto_resume_after_sec;
            };
        }
  in
  if not (Resilience.Keeper_bridge.masc_resilience_enabled ()) then
    {
      resilience_audit_store = None;
      resilience_strategy_executor = None;
      sync_lifecycle_meta;
    }
  else
    match
      (try
         Ok
           (Shared_audit.Store.create
              ~base_dir:(resilience_audit_dir ~config ~keeper_name:meta.name))
       with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn -> Error (Printexc.to_string exn))
    with
    | Error detail ->
        Otel_metric_store.inc_counter Keeper_metrics.(to_string OasExecutionErrors)
          ~labels:[("keeper", meta.name); ("phase", Keeper_oas_execution_error_phase.(to_label Resilience_audit_store))]
          ();
        Log.Keeper.error ~keeper_name:meta.name
          "resilience audit store unavailable; execution disabled: %s"
          detail;
        {
          resilience_audit_store = None;
          resilience_strategy_executor = None;
          sync_lifecycle_meta;
        }
    | Ok audit_store ->
        let executor =
          make_post_turn_resilience_executor ~config ~meta
            ~on_paused:(fun meta -> Atomic.set paused_meta (Some meta))
        in
        {
          resilience_audit_store = Some audit_store;
          resilience_strategy_executor = Some executor;
          sync_lifecycle_meta;
        }

let persist_and_enqueue_partial_commit_continue_gate
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(failure_reason : Keeper_registry.failure_reason)
    ~(committed_tools : string list)
    ~(error_detail : string) : ((keeper_meta * string), string) result =
  let gate_id = Keeper_hitl_continue_gate.generate_id () in
  let* paused_meta =
    Keeper_hitl_continue_gate.install
      ~config
      ~meta
      ~gate_id
      ~origin:Keeper_latched_reason.Partial_commit
      ~committed_tools
  in
  let reason_text = Keeper_registry.failure_reason_to_string failure_reason in
  let input =
    `Assoc [
      ("kind", `String "continue_gate_required");
      ("keeper_name", `String paused_meta.name);
      ("gate_id", `String gate_id);
      ("failure_reason", `String reason_text);
      ("error_detail", `String error_detail);
      ("committed_tools", `List (List.map (fun tool -> `String tool) committed_tools));
    ]
  in
  let approval_id =
    Keeper_approval_queue.submit_pending_blocking
      ~keeper_name:paused_meta.name
      ~tool_name:"keeper_continue_after_partial_commit"
      ~input
      ~risk_level:Keeper_approval_queue.Critical
      ~base_path:config.base_path
      ~on_resolution:(fun ~approval_id:_ decision ->
        let plan commit =
          Keeper_approval_queue.blocking_resolution_plan
            ~effect_key:("continue_gate:" ^ gate_id)
            ~commit
        in
        match decision with
        | Agent_sdk.Hooks.Edit _ -> raise Partial_commit_gate_edit_unsupported
        | Agent_sdk.Hooks.Approve ->
          plan (fun () ->
            match
              Keeper_hitl_continue_gate.resolve
                ~config
                ~keeper_name:paused_meta.name
                ~gate_id
                ~decision:Keeper_hitl_continue_gate.Approve
            with
            | Ok resumed_meta ->
            Keeper_registry.set_failure_reason
              ~base_path:config.base_path
              paused_meta.name
              None;
            Keeper_registry.reset_turn_failures
              ~base_path:config.base_path
              paused_meta.name;
            fun () ->
              (match read_meta config resumed_meta.name with
               | Ok (Some authoritative_meta) ->
                 Keeper_registry.sync_persisted_meta_if_newer
                   ~base_path:config.base_path
                   authoritative_meta.name
                   authoritative_meta;
                 if authoritative_meta.paused
                 then
                   Log.Keeper.info
                     "%s: partial-commit gate approved; a newer operator pause remains authoritative"
                     authoritative_meta.name
                 else (
                   wake_resumed_keeper_fiber
                     ~config
                     ~keeper_name:authoritative_meta.name
                     ();
                   Log.Keeper.info
                     "%s: partial-commit continue gate approved; auto-resumed keeper"
                     authoritative_meta.name)
               | Ok None ->
                 Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
                   ~config
                   ~keeper_name:resumed_meta.name
                   ~side_effect:"partial-commit resume post-removal meta refresh"
                   ~severity:`Error
                   "persisted keeper metadata disappeared after approval"
               | Error err ->
                 Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
                   ~config
                   ~keeper_name:resumed_meta.name
                   ~side_effect:"partial-commit resume post-removal meta refresh"
                   ~severity:`Error
                   err)
            | Error err ->
            Log.Keeper.error
              "%s: partial-commit continue gate approved but keeper resume sync failed: %s"
              paused_meta.name
              err;
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RuntimeSyncFailures)
              ~labels:[ "keeper", meta.name; "site", "resume_sync" ]
              ();
            raise (Partial_commit_gate_sync_failed err))
        | Agent_sdk.Hooks.Reject reason ->
          plan (fun () ->
            match
              Keeper_hitl_continue_gate.resolve
                ~config
                ~keeper_name:paused_meta.name
                ~gate_id
                ~decision:Keeper_hitl_continue_gate.Reject
            with
            | Ok rejected_meta ->
            fun () ->
              Keeper_registry.set_failure_reason
                ~base_path:config.base_path
                rejected_meta.name
                None;
              Log.Keeper.warn
                "%s: partial-commit continue gate rejected; keeper remains operator-paused (%s)"
                rejected_meta.name
                reason
            | Error err ->
            Log.Keeper.error
              "%s: partial-commit continue gate rejection persistence failed: %s (reason=%s)"
              paused_meta.name
              err
              reason;
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string RuntimeSyncFailures)
              ~labels:[ "keeper", meta.name; "site", "pause_sync" ]
              ();
            raise (Partial_commit_gate_sync_failed err)))
      ()
  in
  Ok (paused_meta, approval_id)

(* Dedupe "mixed runtime context budget" log: the values are constant
   per (keeper_name, primary_budget, runtime_budget) because runtime config
   is static at startup.  Logging per turn produces 15-20 duplicates per
   keeper per minute under load. Track the same tuple we've already
   announced and skip subsequent identical log lines. The cache is an
   immutable [StringMap] under an [Atomic.t] so concurrent turns can update
   it without an Eio mutex. *)
let runtime_budget_logged : unit StringMap.t Atomic.t =
  Atomic.make StringMap.empty

let runtime_budget_log_key ~keeper_name ~primary_budget ~runtime_budget =
  Printf.sprintf "%s|%d|%d" keeper_name primary_budget runtime_budget

let resolved_max_context_for_turn ~(meta : keeper_meta) : int =
  let resolution =
    Keeper_context_runtime.resolve_max_context_resolution_of_meta meta
  in
  if resolution.primary_budget < resolution.runtime_budget then begin
    let key =
      runtime_budget_log_key
        ~keeper_name:meta.name
        ~primary_budget:resolution.primary_budget
        ~runtime_budget:resolution.runtime_budget
    in
    let rec log_once () =
      let old = Atomic.get runtime_budget_logged in
      if StringMap.mem key old
      then ()
      else
        let new_map = StringMap.add key () old in
        if Atomic.compare_and_set runtime_budget_logged old new_map
        then
          Log.Keeper.info
            "%s: mixed runtime context budget primary=%d runtime_max=%d; using primary for initial turn budget"
            meta.name resolution.primary_budget resolution.runtime_budget
        else log_once ()
    in
    log_once ()
  end;
   (match resolution.requested_override with
    | Some requested ->
     Log.Keeper.debug
       "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d"
       meta.name requested resolution.turn_budget resolution.primary_budget
       resolution.effective_budget
   | None -> ());
  resolution.effective_budget
