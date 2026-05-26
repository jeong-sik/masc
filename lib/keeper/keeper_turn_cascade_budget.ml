(* Keeper_turn_cascade_budget — cascade execution types, fail-open rotation,
   provider timeout budget resolution, context overflow observation, keeper pause/resume
   sync, partial-commit continue gate, and context budget resolution.

   Extracted from keeper_unified_turn.ml (L501-1079) during the god-file split. *)

open Keeper_types
open Keeper_exec_context
module EC = Keeper_error_classify

type cascade_execution = {
  cascade_name : Cascade_name.t;
  max_context_resolution : Keeper_exec_context.max_context_resolution;
  max_context : int;
  temperature : float;
  max_tokens : int;
}

let fail_open_rotation_cascades_from_catalog =
  Keeper_turn_cascade_budget_routing.fail_open_rotation_cascades_from_catalog

let active_fail_open_rotation_cascades =
  Keeper_turn_cascade_budget_routing.active_fail_open_rotation_cascades

let next_fail_open_cascade_for_turn =
  Keeper_turn_cascade_budget_routing.next_fail_open_cascade_for_turn

let sdk_error_kind = Keeper_turn_cascade_budget_routing.sdk_error_kind
let record_turn_failure_stress =
  Keeper_turn_cascade_budget_routing.record_turn_failure_stress

include Keeper_turn_cascade_budget_provider_timeout

(* RFC-OAS-XXX (Team JJ §6) POC, 2026-05-21
   ------------------------------------------------------------------
   Typed admission decision for an upcoming cascade attempt.

   Background: 1077/24h [provider_timeout] events, ~74% from retry
   paths ([adaptive_*_retry] / [turn_budget_*_retry]). The current caller in
   [Keeper_unified_turn.ml:589-615] calls
   [resolve_bounded_provider_timeout_budget_with_turn_budget] and, when it
   returns [None] for a retry, emits a turn-owned timeout instead of
   minting an [Provider_timeout] root cause. That keeps two
   different failure semantics into one wire code:
     (a) the cascade attempt never started because admission budget
         was insufficient, and
     (b) an actual provider attempt ran and the server timed out.
   Mixing them inflates the [provider_timeout] signature and hides
   the retry-admission rate.

   This function returns a typed admission decision. It does NOT
   change emission semantics on its own — that requires a new
   [masc_internal_error] variant ([Retry_admission_denied]) which is
   surface-breaking and deferred to RFC. The gate is exposed so
   callers can branch before invoking the attempt loop, and so that
   a subsequent PR can swap the emission path without touching the
   gate logic.

   Anti-pattern self-check (software-development.md §workaround):
   - Not telemetry-as-fix (§1): does not add a counter; returns a
     typed Result that the caller must consume.
   - Not string classifier (§2): closed-sum reason, no substring.
   - Not N-of-M (§3): single SSOT function; the followup variant
     change is the natural typed boundary expansion. *)

type retry_admission_denial =
  Cascade_internal_error.retry_admission_denial =
  | Retry_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
      adaptive_timeout_s : float;
      allow_wall_clock_retry_budget : bool;
    }
  | First_attempt_budget_below_min of {
      projected_usable_budget_s : float;
      min_required_s : float;
      remaining_turn_budget_s : float;
    }

type attempt_kind = Keeper_turn_cascade_budget_admission.attempt_kind =
  | First_attempt
  | Retry_attempt

let attempt_kind_is_retry =
  Keeper_turn_cascade_budget_admission.attempt_kind_is_retry
let retry_admission_denial_to_yojson =
  Cascade_internal_error.retry_admission_denial_to_yojson

let decide_retry_admission_for_turn
    ~(remaining_turn_budget_s : float)
    ~(attempt_kind : attempt_kind)
    ~(allow_wall_clock_retry_budget : bool)
    ~(estimated_input_tokens : int)
    ~(max_turns : int) : (unit, retry_admission_denial) result =
  let runtime = Keeper_runtime_resolved.current () in
  let adaptive_timeout_sec = Keeper_runtime_resolved.oas_call_timeout_sec () in
  let is_retry = attempt_kind_is_retry attempt_kind in
  if is_retry then
    let time_spent_in_turn =
      runtime.turn_timeout_sec.value -. remaining_turn_budget_s
    in
    let usable_retry_budget = adaptive_timeout_sec -. time_spent_in_turn in
    let usable_wall_clock_budget =
      remaining_turn_budget_s -. provider_timeout_guard_sec
    in
    let projected_usable_budget_s =
      if usable_retry_budget >= min_provider_timeout_budget_sec then
        usable_retry_budget
      else if allow_wall_clock_retry_budget then usable_wall_clock_budget
      else usable_retry_budget
    in
    if remaining_turn_budget_s <= 0.0 then
      Error
        (Retry_budget_below_min
           {
             projected_usable_budget_s;
             min_required_s = min_provider_timeout_budget_sec;
             remaining_turn_budget_s;
             adaptive_timeout_s = adaptive_timeout_sec;
             allow_wall_clock_retry_budget;
           })
    else if usable_retry_budget >= min_provider_timeout_budget_sec then Ok ()
    else if
      allow_wall_clock_retry_budget
      && usable_wall_clock_budget >= min_provider_timeout_budget_sec
    then Ok ()
    else
      Error
        (Retry_budget_below_min
           {
             projected_usable_budget_s;
             min_required_s = min_provider_timeout_budget_sec;
             remaining_turn_budget_s;
             adaptive_timeout_s = adaptive_timeout_sec;
             allow_wall_clock_retry_budget;
           })
  else
    let usable_budget = remaining_turn_budget_s -. provider_timeout_guard_sec in
    if usable_budget >= min_provider_timeout_budget_sec then Ok ()
    else
      Error
        (First_attempt_budget_below_min
           {
             projected_usable_budget_s = usable_budget;
             min_required_s = min_provider_timeout_budget_sec;
             remaining_turn_budget_s;
           })

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

let cascade_reason_is_structural_attempt_timeout
    (reason : Keeper_types.cascade_exhaustion_reason) : bool =
  (* Typed match only. Producers must construct [Structural_attempt_timeout]
     explicitly; free-form OAS-ceiling-looking text remains [Other_detail].
     Enumerate every constructor so a new reason variant fails to compile here
     rather than silently falling through to [false]. *)
  match reason with
  | Keeper_types.Structural_attempt_timeout _ -> true
  | Keeper_types.Connection_refused
  | Keeper_types.Dns_failure
  | Keeper_types.No_providers_available
  | Keeper_types.All_providers_failed
  | Keeper_types.Candidates_filtered_after_cycles
  | Keeper_types.Max_turns_exceeded
  | Keeper_types.Other_detail _ -> false

let degraded_retry_bypasses_slot_phase_guard
    (err : Agent_sdk.Error.sdk_error) : bool =
  (* Enumerate every [masc_internal_error] variant plus [None] so the
     compiler flags any new constructor here. The old [_ -> false] silently
     extended the "not a budget exhaustion" set whenever a new error class
     was added to Cascade_error_classify, which is exactly the wrong default
     for a guard that decides whether to bypass slot-phase admission. *)
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Provider_timeout _) -> true
  | Some (Keeper_turn_driver.Cascade_exhausted { reason; _ })
    when cascade_reason_is_structural_attempt_timeout reason ->
      true
  | Some
      ( Keeper_turn_driver.Cascade_exhausted _
      | Keeper_turn_driver.Capacity_backpressure _
      | Keeper_turn_driver.Resumable_cli_session _
      | Keeper_turn_driver.No_tool_capable_provider _
      | Keeper_turn_driver.Accept_rejected _
      | Keeper_turn_driver.Admission_queue_timeout _
      | Keeper_turn_driver.Admission_queue_rejected _
      | Keeper_turn_driver.Turn_timeout _
      | Keeper_turn_driver.Max_tokens_ceiling_violation _
      | Keeper_turn_driver.Ambiguous_post_commit _
      (* RFC-0158: admission denial is not an OAS-budget timeout bypass. *)
      | Keeper_turn_driver.Retry_admission_denied _
      (* RFC-0159 Phase A: Internal_* variants are not OAS-budget timeouts. *)
      | Keeper_turn_driver.Internal_unhandled_exception _
      | Keeper_turn_driver.Internal_bridge_exception _
      | Keeper_turn_driver.Internal_contract_rejected _ )
  | None ->
    false

let reclassify_provider_timeout_for_attempt
    ~(provider_timeout_budget : provider_timeout_budget option)
    (err : Agent_sdk.Error.sdk_error) : Agent_sdk.Error.sdk_error =
  match err, provider_timeout_budget with
  | Agent_sdk.Error.Api (Timeout { message }), Some provider_timeout_budget
    when EC.is_structural_oas_timeout_message message ->
      Keeper_turn_driver.sdk_error_of_masc_internal_error
        (Keeper_turn_driver.Provider_timeout
           {
             budget_sec = provider_timeout_budget.effective_timeout_sec;
             keeper_turn_timeout_sec =
               provider_timeout_budget.keeper_turn_timeout_sec;
             estimated_input_tokens = provider_timeout_budget.estimated_input_tokens;
             source = provider_timeout_budget.source;
             remaining_turn_budget_sec =
               Some provider_timeout_budget.remaining_turn_budget_sec;
             min_required_sec = min_provider_timeout_budget_sec;
             phase = "cascade_attempt_watchdog";
           })
  | _ -> err

let attempt_watchdog_outer_turn_reserve_sec = 1.0

let attempt_watchdog_timeout_sec
    ~(remaining_turn_budget_s : float)
    (provider_timeout_budget : provider_timeout_budget) : float =
  let desired =
    provider_timeout_budget.effective_timeout_sec +. provider_timeout_guard_sec
  in
  let cap_before_outer_timeout =
    Float.max 0.001
      (remaining_turn_budget_s -. attempt_watchdog_outer_turn_reserve_sec)
  in
  let floor =
    Float.min min_provider_timeout_budget_sec cap_before_outer_timeout
  in
  Float.max floor (Float.min desired cap_before_outer_timeout)

type degraded_retry_budget_decision =
  | No_degraded_retry
  | Degraded_retry_slot_phase_exhausted of EC.degraded_retry
  | Degraded_retry_budget_exhausted of EC.degraded_retry
  | Degraded_retry_allowed of EC.degraded_retry

let next_fail_open_cascade_for_turn_with_budget
    ?rotation_cascades
    ~(base_cascade : string)
    ~(effective_cascade : string)
    ~(tool_requirement : Keeper_agent_tool_surface.tool_requirement)
    ~(attempted_cascades : string list)
    ~(estimated_input_tokens : int)
    ~(max_turns : int)
    ?time_spent_in_turn_s
    ~(remaining_turn_budget_s : float)
    (err : Agent_sdk.Error.sdk_error) : degraded_retry_budget_decision =
  match
    next_fail_open_cascade_for_turn
      ?rotation_cascades
      ~base_cascade ~effective_cascade ~tool_requirement
      ~attempted_cascades err
  with
  | None -> No_degraded_retry
  | Some retry ->
      (* The candidate is always a retry, so use per-attempt budget semantics
         regardless of whether the current attempt was itself a retry. *)
      let first_contract_rotation =
        EC.is_required_tool_contract_violation err
        && List.length attempted_cascades <= 1
      in
      if
        match time_spent_in_turn_s with
        | Some time_spent_in_turn_s ->
            (not (degraded_retry_slot_phase_available ~time_spent_in_turn_s))
            && not (degraded_retry_bypasses_slot_phase_guard err)
            && not first_contract_rotation
        | None -> false
      then Degraded_retry_slot_phase_exhausted retry
      else if
        provider_retry_budget_available_for_turn
          ~allow_wall_clock_retry_budget:true
          ~is_retry:true ~estimated_input_tokens ~max_turns
          ~remaining_turn_budget_s
      then Degraded_retry_allowed retry
      else Degraded_retry_budget_exhausted retry

type turn_event_bus_overflow =
  Keeper_turn_cascade_budget_event_bus.turn_event_bus_overflow = {
  estimated_tokens : int;
  limit_tokens : int;
}

type turn_event_bus_compaction =
  Keeper_turn_cascade_budget_event_bus.turn_event_bus_compaction = {
  before_tokens : int;
  after_tokens : int;
  tokens_freed : int;
  phase_hint : string;
}

type turn_event_bus_summary =
  Keeper_turn_cascade_budget_event_bus.turn_event_bus_summary = {
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
  Keeper_turn_cascade_budget_event_bus.empty_turn_event_bus_summary

let merge_turn_event_bus_summary =
  Keeper_turn_cascade_budget_event_bus.merge_turn_event_bus_summary

let add_payload_kind =
  Keeper_turn_cascade_budget_event_bus.add_payload_kind

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
      | Agent_sdk.Error.Agent (TokenBudgetExceeded { kind = "Input"; used; limit }) ->
          Keeper_state_machine.Context_overflow_detected
            {
              source = `Oas_signal;
              token_count = used;
              limit_tokens = Some limit;
            }
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

let pause_keeper_for_overflow
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(reason : string) : keeper_meta =
  match
    Keeper_supervisor_pause_policy.handle_auto_pause_from_meta
      ~config
      ~meta
      ~reason_tag:"overflow"
      ~lifecycle_detail:(Printf.sprintf "context_overflow %s" reason)
      ~log_message:(Printf.sprintf "keeper paused after unresolved context overflow (%s)" reason)
      ~blocker_class:None
      ~resume_policy:Keeper_supervisor_pause_policy.Auto_resume_with_backoff
      ()
  with
  | Ok paused_meta ->
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
            Keeper_supervisor_pause_policy.Auto_resume_with_backoff;
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
    paused_meta

let sync_keeper_paused_state_impl
    ~(resume_policy : Keeper_supervisor_pause_policy.crash_pause_resume_policy option)
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(paused : bool) : (keeper_meta, string) result =
  let auto_resume_after_sec =
    match paused, resume_policy with
    | true, Some policy ->
      Keeper_supervisor_pause_policy.auto_resume_after_sec_for_policy meta policy
    | _ -> meta.auto_resume_after_sec
  in
  let synced_meta =
    {
      meta with
      paused;
      auto_resume_after_sec;
      updated_at = now_iso ();
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
    write_meta_with_merge
      ~merge:Keeper_meta_merge.heartbeat_fields_from_disk
      config synced_meta
  with
  | Error err ->
      Prometheus.inc_counter
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
  | Ok () ->
      Keeper_registry.update_meta ~base_path:config.base_path meta.name synced_meta;
      Keeper_turn_helpers.dispatch_keeper_phase_event_checked
        ~config
        ~keeper_name:meta.name
        ~side_effect:(Printf.sprintf "%s sync phase update"
                        (if paused then "pause" else "resume"))
        (if paused
         then Keeper_state_machine.Operator_pause
         else Keeper_state_machine.Operator_resume);
      (if not paused then
         match Keeper_registry.get ~base_path:config.base_path meta.name with
         (* tla-lint: allow-mutation: fiber signal — wake on resume from cascade budget gate *)
         | Some entry -> Atomic.set entry.fiber_wakeup true
         | None ->
             Keeper_turn_helpers.report_keeper_cycle_side_effect_issue
               ~config
               ~keeper_name:meta.name
               ~side_effect:"resume sync fiber wakeup"
               "registry entry missing after metadata update");
      Ok synced_meta

let sync_keeper_paused_state ~(config : Coord.config) ~(meta : keeper_meta) ~paused
  =
  sync_keeper_paused_state_impl ~resume_policy:None ~config ~meta ~paused

let sync_keeper_paused_state_with_resume_policy
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(paused : bool)
    ~(resume_policy : Keeper_supervisor_pause_policy.crash_pause_resume_policy)
  : (keeper_meta, string) result
  =
  sync_keeper_paused_state_impl
    ~resume_policy:(Some resume_policy)
    ~config
    ~meta
    ~paused

let current_keeper_meta ~(config : Coord.config) ~(fallback_meta : keeper_meta) =
  match Keeper_registry.get ~base_path:config.base_path fallback_meta.name with
  | Some entry -> entry.meta
  | None -> fallback_meta

type post_turn_resilience_handles = {
  resilience_audit_store : Shared_audit.Store.t option;
  resilience_strategy_executor : Resilience.Recovery.strategy_executor option;
  sync_lifecycle_meta : post_turn_lifecycle -> post_turn_lifecycle;
}

let resilience_audit_dir
    ~(config : Coord.config)
    ~(keeper_name : string) : string =
  let masc_root =
    Common.masc_dir_from_base_path ~base_path:config.base_path
  in
  Filename.concat
    (Filename.concat masc_root "resilience_audit")
    (Coord_utils.safe_filename keeper_name)

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
    ~(config : Coord.config)
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
            ; cascade_name = None
            }));
    match
      sync_keeper_paused_state_with_resume_policy
        ~config
        ~meta:latest_meta
        ~paused:true
        ~resume_policy:Keeper_supervisor_pause_policy.Auto_resume_with_backoff
    with
    | Ok paused_meta ->
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
        Log.Keeper.warn "keeper:%s post-turn resilience event: %s"
          meta.name (resilience_execution_event_to_string event));
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
    ~(config : Coord.config)
    ~(meta : keeper_meta) : post_turn_resilience_handles =
  let paused_meta = ref None in
  let sync_lifecycle_meta lifecycle =
    match !paused_meta with
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
        Prometheus.inc_counter Keeper_metrics.(to_string OasExecutionErrors)
          ~labels:[("keeper", meta.name); ("phase", Keeper_oas_execution_error_phase.(to_label Resilience_audit_store))]
          ();
        Log.Keeper.error
          "keeper:%s resilience audit store unavailable; execution disabled: %s"
          meta.name detail;
        {
          resilience_audit_store = None;
          resilience_strategy_executor = None;
          sync_lifecycle_meta;
        }
    | Ok audit_store ->
        let executor =
          make_post_turn_resilience_executor ~config ~meta
            ~on_paused:(fun meta -> paused_meta := Some meta)
        in
        {
          resilience_audit_store = Some audit_store;
          resilience_strategy_executor = Some executor;
          sync_lifecycle_meta;
        }

let enqueue_partial_commit_continue_gate
    ~(config : Coord.config)
    ~(meta : keeper_meta)
    ~(failure_reason : Keeper_registry.failure_reason)
    ~(committed_tools : string list)
    ~(error_detail : string) : string =
  let reason_text = Keeper_registry.failure_reason_to_string failure_reason in
  let input =
    `Assoc [
      ("kind", `String "continue_gate_required");
      ("keeper_name", `String meta.name);
      ("failure_reason", `String reason_text);
      ("error_detail", `String error_detail);
      ("committed_tools", `List (List.map (fun tool -> `String tool) committed_tools));
    ]
  in
  Keeper_approval_queue.submit_pending
    ~keeper_name:meta.name
    ~tool_name:"keeper_continue_after_partial_commit"
    ~input
    ~risk_level:Keeper_approval_queue.Critical
    ~base_path:config.base_path
    ~on_resolution:(fun decision ->
      let latest_meta = current_keeper_meta ~config ~fallback_meta:meta in
      match decision with
      | Agent_sdk.Hooks.Approve
      | Agent_sdk.Hooks.Edit _ ->
        (match sync_keeper_paused_state ~config ~meta:latest_meta ~paused:false with
         | Ok resumed_meta ->
             Keeper_registry.set_failure_reason ~base_path:config.base_path meta.name None;
             Keeper_registry.reset_turn_failures ~base_path:config.base_path meta.name;
             Log.Keeper.info
               "%s: partial-commit continue gate approved; auto-resumed keeper"
               resumed_meta.name
         | Error err ->
             Log.Keeper.error
               "%s: partial-commit continue gate approved but keeper resume sync failed: %s"
               meta.name err);
             Prometheus.inc_counter
               Keeper_metrics.(to_string CascadeSyncFailures)
               ~labels:[("keeper", meta.name); ("site", Keeper_cascade_sync_failure_site.(to_label Resume_sync))]
               ()
      | Agent_sdk.Hooks.Reject reason ->
        (match sync_keeper_paused_state ~config ~meta:latest_meta ~paused:true with
         | Ok paused_meta ->
             Keeper_registry.set_failure_reason
               ~base_path:config.base_path meta.name
               (Some failure_reason);
             Log.Keeper.warn
               "%s: partial-commit continue gate rejected; keeper remains paused (%s)"
               paused_meta.name reason
         | Error err ->
             Log.Keeper.error
               "%s: partial-commit continue gate rejected but keeper pause sync failed: %s (reason=%s)"
               meta.name err reason);
             Prometheus.inc_counter
               Keeper_metrics.(to_string CascadeSyncFailures)
               ~labels:[("keeper", meta.name); ("site", Keeper_cascade_sync_failure_site.(to_label Pause_sync))]
               ())
    ()

(* Dedupe "mixed cascade context budget" log: the values are constant
   per (keeper_name, model_labels) because cascade config is static at
   startup.  Logging per turn produces 15-20 duplicates per keeper per
   minute under load. Track (name, primary, cascade_max) tuples we've
   already announced and skip subsequent identical log lines. *)
let cascade_budget_logged : (string * int * int, unit) Hashtbl.t =
  Hashtbl.create 16

let resolved_max_context_for_turn
    ~(meta : keeper_meta)
    (model_labels : string list) : int =
  let resolution =
    Keeper_exec_context.resolve_max_context_resolution
      ~requested_override:meta.max_context_override model_labels
  in
  if resolution.primary_budget < resolution.cascade_budget then begin
    let key = (meta.name, resolution.primary_budget, resolution.cascade_budget) in
    if not (Hashtbl.mem cascade_budget_logged key) then begin
      Hashtbl.add cascade_budget_logged key ();
      Log.Keeper.info
        "%s: mixed cascade context budget primary=%d cascade_max=%d; using primary for initial turn budget"
        meta.name resolution.primary_budget resolution.cascade_budget
    end
  end;
   (match resolution.requested_override with
    | Some requested ->
     Log.Keeper.debug
       "%s: using max_context_override=%d context_budget=%d primary_budget=%d effective_budget=%d"
       meta.name requested resolution.turn_budget resolution.primary_budget
       resolution.effective_budget
   | None -> ());
  resolution.effective_budget
