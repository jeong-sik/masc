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
  | Keeper_turn_driver.Session_conflict -> Session_conflict
  | Keeper_turn_driver.Capacity_exhausted -> Capacity_exhausted
  | Keeper_turn_driver.Other_detail detail -> Other_detail detail
;;

let blocker_class_of_core_error (err : Agent_core.Error.t) : blocker_class option =
  match Keeper_error_classify.recoverable_runtime_failure_reason err with
  | Some Keeper_error_classify.Capacity_backpressure -> Some Capacity_backpressure
  | _ ->
  match Keeper_turn_driver.classify_masc_internal_error err with
  | Some (Keeper_turn_driver.Capacity_backpressure _) -> Some Capacity_backpressure
  | Some (Keeper_turn_driver.Runtime_exhausted { reason; _ }) ->
    Some (Runtime_exhausted (blocker_reason_of_turn_driver_reason reason))
  (* Preserve the pre-existing Config-error policy: this local refusal is
     observed through the registry, not a new durable supervisor blocker. *)
  | Some (Keeper_turn_driver.Official_client_recovery_required _) -> None
  | Some (Keeper_turn_driver.Resumable_cli_session _) -> None
  | Some (Keeper_turn_driver.Accept_rejected _) -> None
  (* Typed [Internal_*] variants map to dedicated [blocker_class] values so
     dashboards and operators can tell an unhandled internal failure from a
     clean turn. *)
  | Some (Keeper_turn_driver.Internal_unhandled_exception _) ->
    Some Internal_unhandled_exception
  | Some (Keeper_turn_driver.Internal_bridge_exception _) ->
    Some Internal_bridge_exception
  | Some (Keeper_turn_driver.Internal_contract_rejected _) ->
    Some Internal_contract_rejected
  | Some (Keeper_turn_driver.Incomplete_tool_transcript _) ->
    Some Incomplete_tool_transcript
  | Some (Keeper_turn_driver.Terminal_effect_failed _) ->
    Some Terminal_effect_failed
  | Some (Keeper_turn_driver.Provider_attempt_effect_fenced _) ->
    Some Provider_attempt_effect_fenced
  | Some (Keeper_turn_driver.Tool_correction_lost _) ->
    Some Tool_correction_lost
  (* Neither blocks the keeper: the host stopped one turn, and a closed
     runtime connection is retried on the next candidate. Both answered
     [None] here before RFC-0454 P2 typed them — an [Internal] string and a
     [ProviderUnavailable] respectively — and a new blocker_class would put
     a keeper on the supervisor's blocked list that was never blocked. *)
  | Some (Keeper_turn_driver.Host_stopped_turn _)
  | Some (Keeper_turn_driver.Preempted_before_first_token _)
  | Some (Keeper_turn_driver.Runtime_connection_closed _) -> None
  | Some (Keeper_turn_driver.Receipt_persistence_failed _) ->
    Some Receipt_persistence_failed
  | Some (Keeper_turn_driver.Gate_replay_repair_required _) ->
    Some Gate_replay_repair_required
  | None ->
    (match err with
     | Agent_core.Error.Internal _ | Agent_core.Error.Internal_carried { message = _; _ } -> None
     | Agent_core.Error.Agent
         ( HookExecutionFailed _
         | TerminalToolEffectFailed _
         | TerminalToolDurabilityFailed _
         (* Hitting the declared round ceiling is not a blocked keeper: the
            next turn starts normally against the same history. The turn's
            terminal reason code carries it, which is the visibility this
            needs. *)
         | ToolRoundLimitExceeded _ ) ->
       None
     | Agent_core.Error.Agent (UnrecognizedStopReason _) ->
       Some Agent_core_unrecognized_stop_reason
     | Agent_core.Error.Agent (GuardrailViolation _) -> Some Agent_core_guardrail_violation
     | Agent_core.Error.Agent (TripwireViolation _) -> Some Agent_core_tripwire_violation
     | Agent_core.Error.Agent (InputRequired _) -> Some Agent_core_input_required
     (* Provider-level [Api] errors are surfaced via AGENT_CORE retry / runtime
         layers and do not map to a typed blocker_class by themselves. *)
     | Agent_core.Error.Api _
     | Agent_core.Error.Provider _
     | Agent_core.Error.Mcp _
     | Agent_core.Error.Config _
     | Agent_core.Error.Serialization _
     | Agent_core.Error.Io _
     | Agent_core.Error.Orchestration _ -> None)
;;

(* ── Runtime blocker surface ───────────────────────────────── *)

type runtime_blocker_surface =
  { blocker_class : string
  ; summary : string Lazy.t
  }

let runtime_blocker_surface_class cls = cls

let runtime_blocker_class_label cls =
  blocker_class_to_string (runtime_blocker_surface_class cls)

let is_runtime_exhausted_blocker_class blocker_class =
  String.equal
    blocker_class
    (blocker_class_to_string (Runtime_exhausted (Other_detail "")))
;;

let is_provider_runtime_blocker_class blocker_class =
  String.equal blocker_class "provider_runtime_error"
;;

let is_fiber_unresolved_blocker_class blocker_class =
  String.equal blocker_class (blocker_class_to_string Fiber_unresolved)
;;

let runtime_blocker_surface_of_typed_class ?(summary = "") (cls : blocker_class)
  : runtime_blocker_surface
  =
  let str = runtime_blocker_class_label cls in
  let summary =
    match cls with
    | Capacity_backpressure ->
      if summary = ""
      then "Provider or client capacity backpressure blocked this keeper turn."
      else summary
    | Runtime_exhausted reason ->
      if summary = "" then runtime_exhaustion_summary reason else summary
    | Fiber_unresolved ->
      if summary = ""
      then
        "Keeper turn fiber ended without completion bookkeeping; inspect liveness/finalization wrapper and preserve the original root cause."
      else summary
    (* All remaining blocker_class variants carry no class-specific summary
       transformation — fall back to the live summary or the typed name. *)
    | Agent_core_context_window_exceeded
    | Agent_core_unrecognized_stop_reason
    | Agent_core_guardrail_violation
    | Agent_core_tripwire_violation
    | Agent_core_input_required
    | Internal_unhandled_exception
    | Internal_bridge_exception
    | Internal_contract_rejected
    | Incomplete_tool_transcript
    | Terminal_effect_failed
    | Provider_attempt_effect_fenced
    | Tool_correction_lost
    | Receipt_persistence_failed
    | Gate_replay_repair_required -> if summary = "" then str else summary
  in
  { blocker_class = str; summary = Lazy.from_val summary }
;;

(* The streak is a count and survives a restart without its cause (the
   registry is rebuilt from [Keeper_turn_failure_streak_store], which stores
   only the number). The execution receipt of the failed turn is durable and
   already names the cause, so the summary reads it instead of telling the
   operator to go and find it. The window this fills runs from boot until
   the next successful turn resets the streak.

   Only a newest receipt the failure path wrote is presented as the cause:
   [`Error], and [`Cancelled], which the same path writes for a provider
   wall-clock timeout and for required input
   ([Keeper_agent_error.receipt_outcome_kind_of_core_error]) and which
   advances the streak like any other failure. A cycle that crashed before
   writing a receipt, or a later [`Ok]/[`Skipped] receipt that did not reset
   the streak, would otherwise put a stale or unrelated cause next to this
   count. *)
let turn_failures_summary ~count (latest_receipt : Keeper_execution_receipt.latest_receipt_reading)
  =
  let streak = Printf.sprintf "Keeper turn failed %d consecutive cycle(s)" count in
  let named_cause ~ended (receipt : Keeper_execution_receipt.latest_receipt_summary) =
    Printf.sprintf
      "%s; %s %s with %s%s"
      streak
      ended
      receipt.latest_ended_at
      receipt.latest_terminal_reason_code
      (match receipt.latest_error_message with
       | Some message -> ": " ^ short_preview message
       | None -> " (the receipt has no error.message)")
  in
  match latest_receipt with
  | Keeper_execution_receipt.Latest_receipt
      ({ Keeper_execution_receipt.latest_outcome = `Error; _ } as receipt) ->
    named_cause ~ended:"last failed turn ended" receipt
  | Keeper_execution_receipt.Latest_receipt
      ({ Keeper_execution_receipt.latest_outcome = `Cancelled; _ } as receipt) ->
    named_cause ~ended:"last turn was cancelled; it ended" receipt
  | Keeper_execution_receipt.Latest_receipt
      { Keeper_execution_receipt.latest_outcome = (`Ok | `Skipped) as outcome
      ; latest_terminal_reason_code
      ; latest_ended_at
      ; latest_error_message = _
      } ->
    Printf.sprintf
      "%s; the newest execution receipt (%s %s, ended %s) is not a failed turn, so no \
       receipt names this failure's cause"
      streak
      (Keeper_execution_receipt.outcome_kind_to_string outcome)
      latest_terminal_reason_code
      latest_ended_at
  | Keeper_execution_receipt.No_receipt ->
    Printf.sprintf "%s; no execution receipt names the cause" streak
  | Keeper_execution_receipt.Latest_receipt_undecodable { field } ->
    Printf.sprintf
      "%s; the newest execution receipt has no readable %s, so no cause is shown"
      streak
      field
  | Keeper_execution_receipt.Receipt_store_unreadable err ->
    Printf.sprintf
      "%s; execution receipts could not be read (%s)"
      streak
      (Dated_jsonl.read_error_to_string err)
;;

let runtime_blocker_surface_of_failure_reason
      ~(latest_receipt : unit -> Keeper_execution_receipt.latest_receipt_reading)
      (reason : Keeper_registry.failure_reason)
  =
  match reason with
  | Keeper_registry.Heartbeat_consecutive_failures count ->
    Some
      { blocker_class = "heartbeat_failures"
      ; summary = lazy (
          Printf.sprintf
            "Heartbeat failed %d consecutive cycle(s); supervisor recovery is required."
            count)
      }
  | Keeper_registry.Turn_consecutive_failures count ->
    Some
      { blocker_class = "turn_failures"
      ; summary = lazy (turn_failures_summary ~count (latest_receipt ()))
      }
  | Keeper_registry.Stale_termination_storm { count } ->
    Some
      { blocker_class = "stale_termination_storm"
      ; summary = lazy (
          Printf.sprintf
            "Stale watchdog terminated %d keeper cycle(s) in the storm window; operator \
             investigation is required before restart."
            count)
      }
  (* The registry wraps runtime exhaustion in [Provider_runtime_error] with the
     typed reason alongside it ([keeper_unified_turn_types.ml:100-112]). Reading
     the code and dropping the reason is what made the status bridge's
     [runtime_exhausted] arm unreachable: every exhaustion arrived labelled
     "provider_runtime_error" (#30447). *)
  | Keeper_registry.Provider_runtime_error { reason = Some reason; code; detail; _ } ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           (Printf.sprintf
              "Runtime attempts exhausted (%s): %s; inspect the attempt chain before \
               retry."
              code
              detail)
         (Runtime_exhausted reason))
  | Keeper_registry.Provider_runtime_error { code; detail; agent_core_timeout; _ } ->
    (match
       Keeper_provider_runtime_boundary.classify_provider_runtime_error_record
         ?agent_core_timeout
         ~code
         ~detail
         ()
     with
     | Keeper_provider_runtime_boundary.Provider_timeout { source; phase } ->
       let source_label =
         match source with
         | Agent_core_api -> "API"
         | Agent_core_provider -> "Provider"
       in
       let phase_suffix =
         match phase with
         | None -> ""
         | Some phase ->
           " during " ^ Keeper_provider_runtime_boundary.timeout_phase_label phase
       in
       Some
         { blocker_class = "provider_runtime_error"
         ; summary = lazy (
             Printf.sprintf
               "%s timeout%s (%s): %s; keeper can soft-fail and retry with provider cooldown."
               source_label
               phase_suffix
               code
               detail)
         }
     | Keeper_provider_runtime_boundary.No_timeout_observed ->
       (* The record already says what happened: [code] is the typed wire
          ([provider_error_repeating_generation:...], [provider_error_rate_limited],
          ...) and [detail] is the provider boundary's own sentence, which for
          a lane failure also says where the input went next. The summary
          used to call this a catch-all and tell the operator to go and find
          a typed cause, which was wrong whenever the code was typed. *)
       Some
         { blocker_class = "provider_runtime_error"
         ; summary = lazy (Printf.sprintf "Provider runtime error (%s): %s" code detail)
         })
  | Keeper_registry.Official_client_recovery_required recovery ->
    Some
      { blocker_class = "official_client_recovery_required"
      ; summary = lazy (Keeper_internal_error.official_client_recovery_summary recovery)
      }
  | Keeper_registry.Turn_configuration_error { code; field; detail } ->
    Some
      { blocker_class = "turn_configuration_error"
      ; summary = lazy (
          Printf.sprintf
            "Keeper configuration error (%s%s): %s; operator configuration change is required."
            code
            (Option.fold field ~none:"" ~some:(Printf.sprintf " field=%s"))
            detail)
      }
  | Keeper_registry.Fiber_unresolved _ ->
    Some
      (runtime_blocker_surface_of_typed_class
         ~summary:
           "Keeper fiber did not resolve a terminal outcome; supervisor cleanup is \
            required."
         Fiber_unresolved)
  | Keeper_registry.Turn_overflow_failure ->
    Some
      { blocker_class = "turn_overflow_failure"
      ; summary = lazy (
          "The turn's request exceeded the context window. Nothing recovers \
           from this on its own; the Keeper stays active.")
      }
  | Keeper_registry.Exception detail ->
    Some
      { blocker_class = "exception"
      ; summary = lazy (Printf.sprintf "Keeper runtime exception: %s" detail)
      }
  | Keeper_registry.Operator_interrupt ->
    Some
      { blocker_class = "operator_interrupt"
      ; summary = lazy ("Current turn was cancelled by explicit operator request.")
      }
;;
