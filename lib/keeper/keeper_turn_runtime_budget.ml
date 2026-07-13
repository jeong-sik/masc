(* Keeper_turn_runtime_budget — runtime execution types, fail-open rotation,
   provider timeout resolution, context overflow observation, Keeper lifecycle
   sync, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile
open Keeper_context_runtime
module EC = Keeper_error_classify
module StringMap = Set_util.StringMap

type runtime_execution = {
  runtime_id : string;
  max_context_resolution : Keeper_context_runtime.max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int option;
}

let next_fail_open_runtime_for_turn =
  Keeper_turn_runtime_budget_routing.next_fail_open_runtime_for_turn

let sdk_error_kind = Keeper_turn_runtime_budget_routing.sdk_error_kind
include Keeper_turn_runtime_budget_provider_timeout

type degraded_retry_decision =
  | No_degraded_retry
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

let decide_degraded_retry
    ~(base_runtime : string)
    ~(effective_runtime : string)
    ~(attempted_runtimes : string list)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry_decision =
  match
    next_fail_open_runtime_for_turn
      ~base_runtime ~effective_runtime
      ~attempted_runtimes err
  with
  | None -> No_degraded_retry
  | Some retry -> Degraded_retry_allowed retry

let plan_degraded_retry_step
      ~base_runtime
      ~current_runtime_id
      ~attempted_runtimes
      ~attempt
      ~err
      ~allow_retry
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime
  =
  match
    decide_degraded_retry
      ~base_runtime
      ~effective_runtime:current_runtime_id
      ~attempted_runtimes
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
    err =
  match direct_no_progress_retry_reason err with
  | None -> No_degraded_retry
  | Some (EC.Empty_no_progress | EC.Thinking_only_no_progress) ->
    (match
       decide_degraded_retry
         ~base_runtime
         ~effective_runtime
         ~attempted_runtimes
         err
     with
     | Degraded_retry_allowed retry when retry_reason_is_direct_no_progress retry
       -> Degraded_retry_allowed retry
     | _ -> No_degraded_retry)
  | Some _ -> No_degraded_retry

let run_direct_no_progress_retry_loop
      ~keeper_name
      ~base_runtime
      ~initial_runtime
      ~initial_max_context
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

let record_overflow_failure
    ~(config : Workspace.config)
    ~(meta : keeper_meta)
    ~(reason : string) : unit =
  Keeper_registry.set_failure_reason
    ~base_path:config.base_path
    meta.name
    (Some Keeper_registry.Turn_overflow_failure);
  Log.Keeper.warn
    "%s: unresolved context overflow observed (%s); Keeper lifecycle remains active"
    meta.name
    reason

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
  : Resilience.Recovery.strategy_executor =
  let record_recovery_failure ~code ~detail =
    let detail = short_resilience_detail detail in
    Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name
      (Some
         (Keeper_registry.Provider_runtime_error
            { code; detail; provider_id = None; http_status = None
            ; runtime_id = None
            ; reason = None
            }));
    Log.Keeper.warn ~keeper_name:meta.name
      "%s: post-turn resilience strategy failure (code=%s) observed; Keeper \
       lifecycle remains active: %s"
      meta.name code detail
  in
  let fail_with_observation ~code ~detail =
    let detail = short_resilience_detail detail in
    record_recovery_failure ~code ~detail;
    detail
  in
  {
    Resilience.Recovery.run_retry_attempt =
      (fun ~attempt ->
        let detail =
          Printf.sprintf
            "post-turn resilience retry attempt %d has no operation-specific \
             retry callback"
            attempt
        in
        Resilience.Recovery.Fatal_failure
          (fail_with_observation ~code:"resilience_retry_unbound" ~detail));
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
             (value=%s confidence_delta=%.3f)"
            (short_resilience_detail value) confidence_delta
        in
        Error
          (fail_with_observation ~code:"resilience_fallback_unbound" ~detail));
    request_handoff =
      (fun ~message ~preserve_state ->
        let detail =
          Printf.sprintf
            "post-turn resilience handoff requested preserve_state=%b: %s"
            preserve_state message
        in
        record_recovery_failure ~code:"resilience_handoff" ~detail;
        Ok ());
    abort =
      (fun ~reason ->
        let detail =
          Printf.sprintf
            "post-turn resilience abort requested: %s"
            reason
        in
        record_recovery_failure ~code:"resilience_abort" ~detail;
        Ok ());
  }

let post_turn_resilience_handles
    ~(config : Workspace.config)
    ~(meta : keeper_meta) : post_turn_resilience_handles =
  let sync_lifecycle_meta lifecycle = lifecycle in
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
        let executor = make_post_turn_resilience_executor ~config ~meta in
        {
          resilience_audit_store = Some audit_store;
          resilience_strategy_executor = Some executor;
          sync_lifecycle_meta;
        }

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
