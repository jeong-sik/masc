(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.
    Telemetry surface: blocker_class labels flow to dashboard gauges via
    [runtime_blocker_fields_json] in [keeper_status_bridge.ml].

    @since God file decomposition *)

open Keeper_types

let blocker_class_of_string (reason : string) : blocker_class option =
  let trimmed = String.trim reason in
  if trimmed = ""
  then None
  else if
    String_util.contains_substring_ci trimmed "capacity exhausted"
    || String_util.contains_substring_ci trimmed "capacity_backpressure"
    || String_util.contains_substring_ci trimmed "client capacity"
  then Some Capacity_backpressure
  else if
    String_util.contains_substring_ci
      trimmed
      "turn outcome ambiguous after committed mutating tool call(s)"
  then
    Some
      (if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
       then Ambiguous_post_commit_timeout
       else Ambiguous_post_commit_failure)
  else if String_util.contains_substring_ci trimmed "cascade_exhausted"
  then (
    let reason =
      if String_util.contains_substring_ci trimmed "connection refused"
      then Connection_refused
      else if String_util.contains_substring_ci trimmed "no providers available"
      then No_providers_available
      else if
        String_util.contains_substring_ci trimmed "error_max_turns"
        || String_util.contains_substring_ci trimmed "reached maximum number of turns"
        || String_util.contains_substring_ci trimmed "max turns exceeded"
      then Max_turns_exceeded
      else if String_util.contains_substring_ci trimmed "all providers failed"
      then All_providers_failed
      else Other_detail trimmed
    in
    Some (Cascade_exhausted reason))
  else if String_util.contains_substring_ci trimmed "admission queue wait timeout"
  then Some Admission_queue_wait_timeout
  else if String_util.contains_substring_ci trimmed "autonomous turn slot wait timeout"
  then Some Autonomous_slot_wait_timeout
  else if String_util.contains_substring_ci trimmed "oas budget timeout"
  then Some Turn_timeout
  else if String_util.contains_substring_ci trimmed "turn wall-clock timeout"
  then Some Turn_timeout
  else if
    String_util.contains_substring_ci trimmed "turn_livelock"
    || String_util.contains_substring_ci trimmed "livelock blocked"
  then Some Turn_livelock_blocked
  else if
    (* 2026-05-05: Completion contract violations (e.g. require_tool_use)
       were text-stamped to runtime.last_blocker but left
       runtime.last_blocker_class null because [blocker_class_of_sdk_error]
       returned None on the [Agent_sdk.Error.Agent
       (CompletionContractViolation _)] path and the fallthrough to
       [blocker_class_of_string] had no matching substring.  Variant
       [Completion_contract_violation] was already defined in
       [Keeper_types.blocker_class] — only the mapping was missing.
       Affected production keepers where dashboard "차단된 키퍼" card and
       Prometheus blocker-class series were silent on this failure mode. *)
    String_util.contains_substring_ci trimmed "completion contract"
  then Some Completion_contract_violation
  else if String_util.contains_substring_ci trimmed "cost budget"
  then Some Sdk_cost_budget_exceeded
  else None

let blocker_class_of_sdk_error (err : Agent_sdk.Error.sdk_error) : blocker_class option =
  match Keeper_error_classify.recoverable_cascade_failure_reason err with
  | Some Keeper_error_classify.Capacity_backpressure -> Some Capacity_backpressure
  | _ ->
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Capacity_backpressure _) -> Some Capacity_backpressure
  | Some (Keeper_turn_driver.Cascade_exhausted { reason; _ }) ->
    Some (Cascade_exhausted reason)
  | Some (Keeper_turn_driver.Resumable_cli_session { detail; _ }) ->
    Some (Cascade_exhausted (Other_detail detail))
  | Some (Keeper_turn_driver.No_tool_capable_provider _) -> Some No_tool_capable_provider
  | Some (Keeper_turn_driver.Accept_rejected _) -> None
  | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
    Some Admission_queue_wait_timeout
  | Some (Keeper_turn_driver.Admission_queue_rejected _) -> None
  | Some (Keeper_turn_driver.Provider_timeout _) -> Some Turn_timeout
  | Some (Keeper_turn_driver.Max_tokens_ceiling_violation _) -> None
  | Some (Keeper_turn_driver.Turn_timeout _) -> Some Turn_timeout
  | Some (Keeper_turn_driver.Ambiguous_post_commit { is_timeout; _ }) ->
    Some
      (if is_timeout then Ambiguous_post_commit_timeout else Ambiguous_post_commit_failure)
  (* RFC-0158: admission denial — budget too low for any provider attempt.
     Not a cascade-exhaustion or provider-failure blocker; the turn budget
     was simply insufficient. *)
  | Some (Keeper_turn_driver.Retry_admission_denied _) -> None
  (* RFC-0159 Phase A: typed [Internal_*] variants carry an opaque exception
     repr.  They are not yet mapped to a dedicated [blocker_class]; returning
     [None] keeps Phase A scope to typed substrate only.  A follow-up RFC may
  introduce a typed blocker_class for unhandled internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _) -> None
  | Some (Keeper_turn_driver.Internal_bridge_exception _) -> None
  | Some (Keeper_turn_driver.Internal_contract_rejected _) -> None
  | None ->
    (match err with
     | Agent_sdk.Error.Internal msg -> blocker_class_of_string msg
     | Agent_sdk.Error.Agent (Agent_sdk.Error.CompletionContractViolation _) ->
       (* See note on [blocker_class_of_string] above; same gap, same
             enum target.  Direct typed match preferred over text-substring
             fallback when the SDK gave us a structured error. *)
       Some Completion_contract_violation
     | Agent_sdk.Error.Agent (MaxTurnsExceeded _) -> Some Sdk_max_turns_exceeded
     | Agent_sdk.Error.Agent (TokenBudgetExceeded _) -> Some Sdk_token_budget_exceeded
     | Agent_sdk.Error.Agent (CostBudgetExceeded _) -> Some Sdk_cost_budget_exceeded
     | Agent_sdk.Error.Agent (CostBudgetUnenforceable _) -> Some Sdk_cost_budget_exceeded
     | Agent_sdk.Error.Agent (UnrecognizedStopReason _) ->
       Some Sdk_unrecognized_stop_reason
     | Agent_sdk.Error.Agent (IdleDetected _) -> Some Sdk_idle_detected
     | Agent_sdk.Error.Agent (ToolRetryExhausted _) -> Some Sdk_tool_retry_exhausted
     | Agent_sdk.Error.Agent (GuardrailViolation _) -> Some Sdk_guardrail_violation
     | Agent_sdk.Error.Agent (TripwireViolation _) -> Some Sdk_tripwire_violation
     | Agent_sdk.Error.Agent (ExitConditionMet _) -> Some Sdk_exit_condition_met
     | Agent_sdk.Error.Agent (InputRequired _) -> Some Sdk_input_required
     (* Provider-level [Api] errors are surfaced via OAS retry / cascade
         layers and do not map to a typed blocker_class by themselves. *)
     | Agent_sdk.Error.Api _
     | Agent_sdk.Error.Provider _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _
     | Agent_sdk.Error.A2a _ -> None)
;;

(* ── Runtime blocker surface ───────────────────────────────── *)

type runtime_blocker_surface =
  { blocker_class : string
  ; summary : string
  ; continue_gate : bool
  }

let runtime_blocker_surface_class cls = cls

let runtime_blocker_class_label ?(summary = "") cls =
  let _ = summary in
  blocker_class_to_string (runtime_blocker_surface_class cls)

let is_cascade_exhausted_blocker_class blocker_class =
  String.equal
    blocker_class
    (blocker_class_to_string (Cascade_exhausted (Other_detail "")))
;;

let is_no_tool_capable_provider_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string No_tool_capable_provider)
;;

let is_completion_contract_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Completion_contract_violation)
;;

let is_provider_runtime_blocker_class blocker_class =
  String.equal blocker_class "provider_runtime_error"
;;

let is_stale_watchdog_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Stale_turn_timeout)
;;

let is_fiber_unresolved_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Fiber_unresolved)
;;



let runtime_blocker_surface_of_typed_class ?(summary = "") (cls : blocker_class)
  : runtime_blocker_surface
  =
  let surface_cls = runtime_blocker_surface_class cls in
  let str = runtime_blocker_class_label ~summary cls in
  let continue_gate = blocker_class_continue_gate surface_cls in
  let summary =
    match cls with
    | Capacity_backpressure ->
      if summary = ""
      then "Provider or client capacity backpressure blocked this keeper turn."
      else summary
    | Cascade_exhausted reason ->
      if summary = ""
      then cascade_exhaustion_summary reason
      else (
        match Keeper_turn_driver.classify_masc_internal_error_of_string summary with
        | Some (Keeper_turn_driver.Capacity_backpressure _) ->
          "Provider or client capacity backpressure blocked this keeper turn."
        | Some (Keeper_turn_driver.Cascade_exhausted { reason = structured_reason; _ }) ->
          let reason =
            match structured_reason with
            | Other_detail _ -> reason
            | _ -> structured_reason
          in
          cascade_exhaustion_summary reason
        | _ -> summary)
    | Turn_livelock_blocked ->
      if summary = ""
      then "Keeper turn livelock guard blocked repeated dispatch of the same turn."
      else summary
    | Fiber_unresolved ->
      if summary = ""
      then
        "Keeper turn fiber ended without completion bookkeeping; inspect liveness/finalization wrapper and preserve the original root cause."
      else summary
    | Stale_turn_timeout ->
      if summary = ""
      then
        "Watchdog marked the turn stale; inspect watchdog timing and the underlying root cause separately."
      else summary
    | No_tool_capable_provider ->
      (match
         Keeper_turn_driver.classify_masc_internal_error
           (Agent_sdk.Error.Internal summary)
       with
       | Some err ->
         (match Keeper_turn_driver.summary_of_masc_internal_error err with
          | Some structured_summary -> structured_summary
          | None ->
            if summary = ""
            then
              "No configured provider can satisfy the required tool set before dispatch."
            else summary)
       | None ->
         if summary = ""
         then
           "No configured provider can satisfy the required tool set before dispatch."
         else summary)
    | Completion_contract_violation ->
      (* TEL-OK: string literal in blocker classification summary, not an action handler *)
      if summary = ""
      then
        "Provider response violated the required completion/tool contract after dispatch."
      else summary
    (* All remaining blocker_class variants carry no class-specific summary
       transformation — fall back to the live summary or the typed name. *)
    | Ambiguous_post_commit_timeout
    | Ambiguous_post_commit_failure
    | Autonomous_slot_wait_timeout
    | Admission_queue_wait_timeout
    | Turn_timeout_after_queue_wait
    | Turn_timeout
    | Stay_silent_loop
    | Stale_fleet_batch
    | Sdk_max_turns_exceeded
    | Sdk_token_budget_exceeded
    | Sdk_cost_budget_exceeded
    | Sdk_unrecognized_stop_reason
    | Sdk_idle_detected
    | Sdk_tool_retry_exhausted
    | Sdk_guardrail_violation
    | Sdk_tripwire_violation
    | Sdk_exit_condition_met
    | Sdk_input_required -> if summary = "" then str else summary
  in
  { blocker_class = str; summary; continue_gate }
;;

let runtime_blocker_surface_of_legacy_string reason cls =
  match cls with
  | Cascade_exhausted _ -> runtime_blocker_surface_of_typed_class ~summary:reason cls
  (* All other blocker classes carry no embedded reason payload, so the
     legacy string [reason] argument provides the fallback summary. *)
  | Ambiguous_post_commit_timeout
  | Ambiguous_post_commit_failure
  | Capacity_backpressure
  | Autonomous_slot_wait_timeout
  | Admission_queue_wait_timeout
  | Turn_timeout_after_queue_wait
  | Turn_timeout
  | Turn_livelock_blocked
  | Completion_contract_violation
  | No_tool_capable_provider
  | Stay_silent_loop
  | Fiber_unresolved
  | Stale_turn_timeout
  | Stale_fleet_batch
  | Sdk_max_turns_exceeded
  | Sdk_token_budget_exceeded
  | Sdk_cost_budget_exceeded
  | Sdk_unrecognized_stop_reason
  | Sdk_idle_detected
  | Sdk_tool_retry_exhausted
  | Sdk_guardrail_violation
  | Sdk_tripwire_violation
  | Sdk_exit_condition_met
  | Sdk_input_required -> runtime_blocker_surface_of_typed_class ~summary:reason cls
;;

let stale_kill_class_summary (kill_class : Keeper_registry.stale_kill_class) =
  match kill_class with
  | Keeper_registry.Idle_turn { stall_seconds } ->
    Printf.sprintf
      "idle_turn: no completed turn for %.0fs; stale watchdog stopped the keeper before \
       restart."
      stall_seconds
  | Keeper_registry.In_turn_hung { active_seconds; timeout_threshold } ->
    Printf.sprintf
      "in_turn_hung: active turn ran for %.0fs past the %.0fs timeout; stale watchdog \
       stopped the keeper."
      active_seconds
      timeout_threshold
  | Keeper_registry.Mid_turn_no_progress
      { active_seconds
      ; since_progress_seconds
      ; progress_timeout_threshold
      ; last_progress_kind
      } ->
    Printf.sprintf
      "mid_turn_no_progress: active turn ran for %.0fs but produced no progress for %.0fs \
       past the %.0fs progress timeout (last=%s); stale watchdog stopped the keeper."
      active_seconds
      since_progress_seconds
      progress_timeout_threshold
      (Keeper_registry.progress_kind_label last_progress_kind)
  | Keeper_registry.Noop_failure_loop { noop_count } ->
    Printf.sprintf
      "noop_failure_loop: %d consecutive turn(s) produced no tool calls; stale watchdog \
       stopped the keeper."
      noop_count
;;

let runtime_blocker_surface_of_failure_reason (reason : Keeper_registry.failure_reason) =
  match reason with
  | Keeper_registry.Heartbeat_consecutive_failures count ->
    Some
      { blocker_class = "heartbeat_failures"
      ; summary =
          Printf.sprintf
            "Heartbeat failed %d consecutive cycle(s); supervisor recovery is required."
            count
      ; continue_gate = false
      }
  | Keeper_registry.Turn_consecutive_failures count ->
    Some
      { blocker_class = "turn_failures"
      ; summary =
          Printf.sprintf
            "Keeper turn failed %d consecutive cycle(s); inspect the last runtime error \
             before retry."
            count
      ; continue_gate = false
      }
  | Keeper_registry.Stale_turn_timeout kill_class ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:(stale_kill_class_summary kill_class)
         Stale_turn_timeout)
  | Keeper_registry.Stale_termination_storm { count } ->
    Some
      { blocker_class = "stale_termination_storm"
      ; summary =
          Printf.sprintf
            "Stale watchdog terminated %d keeper cycle(s) in the storm window; operator \
             investigation is required before restart."
            count
      ; continue_gate = false
      }
  | Keeper_registry.Provider_timeout_loop { count } ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           (Printf.sprintf
              "Provider timeout repeated %d consecutive cycle(s); keeper was \
               auto-paused before restart loop."
              count)
         Turn_timeout)
  | Keeper_registry.Stale_fleet_batch { distinct_count } ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           (Printf.sprintf
              "Stale watchdog terminated %d distinct keeper(s) inside the fleet batch \
               window; keeper was auto-paused before restart loop."
              distinct_count)
         Stale_fleet_batch)
  | Keeper_registry.Provider_runtime_error { code; detail } ->
    Some
      { blocker_class = "provider_runtime_error"
      ; summary =
          Printf.sprintf
            "Provider runtime catch-all (%s): %s; inspect typed provider/auth/DNS/timeout/capacity cause."
            code
            detail
      ; continue_gate = false
      }
  | Keeper_registry.Tool_required_unsatisfied { code; detail } ->
    Some
      { blocker_class = "tool_required_unsatisfied"
      ; summary = Printf.sprintf "%s: %s" code detail
      ; continue_gate = false
      }
  | Keeper_registry.Ambiguous_partial_commit { kind; detail } ->
    let blocker_class =
      match kind with
      | Keeper_registry.Post_commit_timeout -> "ambiguous_post_commit_timeout"
      | Keeper_registry.Post_commit_failure -> "ambiguous_post_commit_failure"
    in
    Some { blocker_class; summary = detail; continue_gate = true }
  | Keeper_registry.Fiber_unresolved ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           "Keeper fiber did not resolve a terminal outcome; supervisor cleanup is \
            required."
         Fiber_unresolved)
  | Keeper_registry.Turn_overflow_pause ->
    Some
      { blocker_class = "turn_overflow_pause"
      ; summary = "Context overflow with compact retry exhausted; keeper was auto-paused."
      ; continue_gate = false
      }
  | Keeper_registry.Turn_livelock_pause ->
    Some
      { blocker_class = "turn_livelock_pause"
      ; summary = "Turn livelock guard blocked dispatch; keeper was auto-paused."
      ; continue_gate = false
      }
  | Keeper_registry.Exception detail ->
    Some
      { blocker_class = "exception"
      ; summary = Printf.sprintf "Keeper runtime exception: %s" detail
      ; continue_gate = false
      }
;;
