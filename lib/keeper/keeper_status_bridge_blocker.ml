(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.
    telemetry surface: blocker_class labels flow to dashboard gauges via
    [runtime_blocker_fields_json] in [keeper_status_bridge.ml].

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

let blocker_reason_of_turn_driver_reason
    (reason : Keeper_turn_driver.runtime_exhaustion_reason)
  : Keeper_meta_contract.runtime_exhaustion_reason
  =
  match reason with
  | Keeper_turn_driver.Connection_refused -> Connection_refused
  | Keeper_turn_driver.Dns_failure -> Dns_failure
  | Keeper_turn_driver.No_providers_available -> No_providers_available
  | Keeper_turn_driver.All_providers_failed -> All_providers_failed
  | Keeper_turn_driver.Candidates_filtered_after_cycles ->
    Candidates_filtered_after_cycles
  | Keeper_turn_driver.Max_turns_exceeded -> Max_turns_exceeded
  | Keeper_turn_driver.Session_conflict -> Session_conflict
  | Keeper_turn_driver.Structural_attempt_timeout { detail } ->
    Structural_attempt_timeout { detail }
  | Keeper_turn_driver.Capacity_exhausted -> Capacity_exhausted
  | Keeper_turn_driver.Other_detail detail -> Other_detail detail
;;

let blocker_class_of_sdk_error (err : Agent_sdk.Error.sdk_error) : blocker_class option =
  match Keeper_error_classify.recoverable_runtime_failure_reason err with
  | Some Keeper_error_classify.Capacity_backpressure -> Some Capacity_backpressure
  | _ ->
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Capacity_backpressure _) -> Some Capacity_backpressure
  | Some (Keeper_turn_driver.Runtime_exhausted { reason; _ }) ->
    Some (Runtime_exhausted (blocker_reason_of_turn_driver_reason reason))
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> None
  | Some (Keeper_turn_driver.Accept_rejected _) -> Some Completion_contract_violation
  | Some (Keeper_turn_driver.Admission_queue_timeout _) ->
    Some Admission_queue_wait_timeout
  | Some (Keeper_turn_driver.Admission_queue_rejected _) -> None
  | Some (Keeper_turn_driver.Provider_timeout _) -> None
  | Some (Keeper_turn_driver.Turn_timeout _) -> Some Turn_timeout
  | Some (Keeper_turn_driver.Ambiguous_post_commit { is_timeout; _ }) ->
    Some
      (if is_timeout then Ambiguous_post_commit_timeout else Ambiguous_post_commit_failure)
  (* RFC-0159 Phase A: typed [Internal_*] variants carry an opaque exception
     repr.  They are not yet mapped to a dedicated [blocker_class]; returning
     [None] keeps Phase A scope to typed substrate only.  A follow-up RFC may
  introduce a typed blocker_class for unhandled internal failures. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _) -> None
  | Some (Keeper_turn_driver.Internal_bridge_exception _) -> None
  | Some (Keeper_turn_driver.Internal_contract_rejected _) -> None
  | None ->
    (match err with
     | Agent_sdk.Error.Internal _ -> None
     | Agent_sdk.Error.Api (Agent_sdk.Retry.Timeout { message })
       when Keeper_error_classify.is_structural_oas_timeout_message message ->
       Some Oas_agent_execution_timeout
     | Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionTimeout _)
     | Agent_sdk.Error.Agent (Agent_sdk.Error.AgentExecutionIdleTimeout _) ->
       Some Oas_agent_execution_timeout
     | Agent_sdk.Error.Agent (MaxTurnsExceeded _) -> Some Sdk_max_turns_exceeded
     | Agent_sdk.Error.Agent (UnrecognizedStopReason _) ->
       Some Sdk_unrecognized_stop_reason
     | Agent_sdk.Error.Agent (IdleDetected _) -> Some Sdk_idle_detected
     | Agent_sdk.Error.Agent (GuardrailViolation _) -> Some Sdk_guardrail_violation
     | Agent_sdk.Error.Agent (TripwireViolation _) -> Some Sdk_tripwire_violation
     | Agent_sdk.Error.Agent (ExitConditionMet _) -> Some Sdk_exit_condition_met
     | Agent_sdk.Error.Agent (InputRequired _) -> Some Sdk_input_required
     | Agent_sdk.Error.Agent (ToolFailureRecoveryFailed _) ->
       Some Sdk_tool_failure_recovery_failed
     | Agent_sdk.Error.Agent (ToolFailureRecoveryDeferred _) ->
       (* Runtime_agent converts this control result to a typed checkpoint
          before the status bridge. If it is observed here, do not manufacture
          a blocker class for a non-failure. *)
       None
     (* Provider-level [Api] errors are surfaced via OAS retry / runtime
         layers and do not map to a typed blocker_class by themselves. *)
     | Agent_sdk.Error.Api _
     | Agent_sdk.Error.Provider _
     | Agent_sdk.Error.Mcp _
     | Agent_sdk.Error.Config _
     | Agent_sdk.Error.Serialization _
     | Agent_sdk.Error.Io _
     | Agent_sdk.Error.Orchestration _ -> None)
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

let is_runtime_exhausted_blocker_class blocker_class =
  String.equal
    blocker_class
    (blocker_class_to_string (Runtime_exhausted (Other_detail "")))
;;

let is_provider_runtime_blocker_class blocker_class =
  String.equal blocker_class "provider_runtime_error"
;;

let is_stale_turn_timeout_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Stale_turn_timeout)
;;

let is_fiber_unresolved_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Fiber_unresolved)
;;

let no_progress_loop_summary =
  "Keeper auto-paused after repeated no-evidence turns; this is a progress-safety latch, not a provider failure. Operator resume clears the latch."
;;

let runtime_blocker_surface_of_masc_internal_error = function
  | Keeper_turn_driver.Accept_rejected _ as err ->
    let summary =
      Option.value
        ~default:"Provider response violated the completion contract after dispatch."
        (Keeper_turn_driver.summary_of_masc_internal_error err)
    in
    Some
      { blocker_class =
          runtime_blocker_class_label Completion_contract_violation
      ; summary
      ; continue_gate =
          blocker_class_continue_gate Completion_contract_violation
      }
  | Keeper_turn_driver.Runtime_exhausted _
  | Keeper_turn_driver.Capacity_backpressure _
  | Keeper_turn_driver.Resumable_cli_session _
  | Keeper_turn_driver.Admission_queue_timeout _
  | Keeper_turn_driver.Admission_queue_rejected _
  | Keeper_turn_driver.Turn_timeout _
  | Keeper_turn_driver.Provider_timeout _
  | Keeper_turn_driver.Ambiguous_post_commit _
  | Keeper_turn_driver.Internal_unhandled_exception _
  | Keeper_turn_driver.Internal_bridge_exception _
  | Keeper_turn_driver.Internal_contract_rejected _ ->
    None

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
    | Runtime_exhausted reason ->
      if summary = "" then runtime_exhaustion_summary reason else summary
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
    | Oas_agent_execution_timeout ->
      if summary = ""
      then
        "OAS Agent.run reported an execution timeout; inspect whether progress accounting excluded active tool execution."
      else summary
    | Completion_contract_violation ->
      (* TEL-OK: string literal in blocker classification summary, not an action handler *)
      if summary = ""
      then
        "Provider response violated the completion contract after dispatch."
      else summary
    | No_progress_loop -> no_progress_loop_summary
    (* All remaining blocker_class variants carry no class-specific summary
       transformation — fall back to the live summary or the typed name. *)
    | Ambiguous_post_commit_timeout
    | Ambiguous_post_commit_failure
    | Admission_queue_wait_timeout
    | Turn_timeout_after_queue_wait
    | Turn_timeout
    | Stale_fleet_batch
    | Sdk_max_turns_exceeded
    | Sdk_token_budget_exceeded
    | Sdk_cost_budget_exceeded
    | Sdk_unrecognized_stop_reason
    | Sdk_idle_detected
    | Sdk_guardrail_violation
    | Sdk_tripwire_violation
    | Sdk_exit_condition_met
    | Sdk_input_required
    | Sdk_tool_failure_recovery_failed -> if summary = "" then str else summary
  in
  { blocker_class = str; summary; continue_gate }
;;

let stale_kill_class_summary (kill_class : Keeper_registry.stale_kill_class) =
  match kill_class with
  | Keeper_registry.Idle_turn { stall_seconds } ->
    Printf.sprintf
      "idle_turn: no completed turn for %.0fs; stale watchdog stopped the keeper before \
       restart."
      stall_seconds
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
  | Keeper_registry.Completion_contract_violation { detail } ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           (if String.trim detail = ""
            then "Provider response violated the completion contract after dispatch."
            else detail)
         Completion_contract_violation)
  | Keeper_registry.Provider_runtime_error { code; detail; _ } ->
    (match
       Keeper_provider_runtime_boundary.classify_provider_runtime_error_record
         ~code
         ~detail
     with
     | Keeper_provider_runtime_boundary.Provider_timeout _ ->
       Some
         (runtime_blocker_surface_of_typed_class
            ~summary:
              (Printf.sprintf
                 "Provider timeout (%s): %s; keeper can soft-fail and retry with provider cooldown."
                 code
                 detail)
            Turn_timeout)
     | Keeper_provider_runtime_boundary.Not_provider_runtime_failure ->
       Some
         { blocker_class = "provider_runtime_error"
         ; summary =
             Printf.sprintf
               "Provider runtime catch-all (%s): %s; inspect typed provider/auth/DNS/timeout/capacity cause."
               code
               detail
         ; continue_gate = false
         })
  | Keeper_registry.Ambiguous_partial_commit { kind; detail } ->
    let blocker_class =
      match kind with
      | Keeper_registry.Post_commit_timeout -> "ambiguous_post_commit_timeout"
      | Keeper_registry.Post_commit_failure -> "ambiguous_post_commit_failure"
    in
    Some { blocker_class; summary = detail; continue_gate = true }
  | Keeper_registry.Fiber_unresolved _ ->
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
  | Keeper_registry.Operator_interrupt ->
    Some
      { blocker_class = "operator_interrupt"
      ; summary = "Current turn was cancelled by explicit operator request."
      ; continue_gate = true
      }
;;
