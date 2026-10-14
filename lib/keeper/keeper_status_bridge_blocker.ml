(** Keeper_status_bridge_blocker — Blocker class classification and
    runtime blocker surface construction.

    Extracted from [keeper_status_bridge.ml] during godfile decomposition.
    telemetry surface: blocker_class labels flow to dashboard gauges via
    [runtime_blocker_fields_json] in [keeper_status_bridge.ml].

    @since God file decomposition *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

(* ── Runtime blocker surface ───────────────────────────────── *)

type runtime_blocker_class =
  | Blocked_by_heartbeat_failures
  | Blocked_by_turn_failures
  | Blocked_by_runtime_exhaustion
  | Blocked_by_provider_runtime_error
  | Blocked_by_official_client_recovery
  | Blocked_by_turn_configuration_error
  | Blocked_by_unresolved_fiber
  | Blocked_by_exception
  | Blocked_by_operator_interrupt

(* The two classes [Keeper_meta_contract.blocker_class_of_serialized_string]
   also reads take its spelling, so the trust-snapshot decoder and this
   producer cannot drift on them. *)
let runtime_blocker_class_to_string = function
  | Blocked_by_heartbeat_failures -> "heartbeat_failures"
  | Blocked_by_turn_failures -> "turn_failures"
  | Blocked_by_runtime_exhaustion ->
    blocker_class_to_string (Runtime_exhausted (Other_detail ""))
  | Blocked_by_provider_runtime_error -> "provider_runtime_error"
  | Blocked_by_official_client_recovery -> "official_client_recovery_required"
  | Blocked_by_turn_configuration_error -> "turn_configuration_error"
  | Blocked_by_unresolved_fiber -> blocker_class_to_string Fiber_unresolved
  | Blocked_by_exception -> "exception"
  | Blocked_by_operator_interrupt -> "operator_interrupt"
;;

type runtime_blocker_surface =
  { blocker_class : runtime_blocker_class
  ; summary : string Lazy.t
  }

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
      { blocker_class = Blocked_by_heartbeat_failures
      ; summary = lazy (
          Printf.sprintf
            "Heartbeat failed %d consecutive cycle(s); supervisor recovery is required."
            count)
      }
  | Keeper_registry.Turn_consecutive_failures count ->
    Some
      { blocker_class = Blocked_by_turn_failures
      ; summary = lazy (turn_failures_summary ~count (latest_receipt ()))
      }
  (* The registry wraps runtime exhaustion in [Provider_runtime_error] with the
     typed reason alongside it ([keeper_unified_turn_types.ml:100-112]). Reading
     the code and dropping the reason is what made the status bridge's
     [runtime_exhausted] arm unreachable: every exhaustion arrived labelled
     "provider_runtime_error" (#30447). *)
  | Keeper_registry.Provider_runtime_error { reason = Some reason; code; detail; _ } ->
    Some
      { blocker_class = Blocked_by_runtime_exhaustion
      ; summary = lazy (
          Printf.sprintf
            "Runtime attempts exhausted (%s): %s; inspect the attempt chain before retry."
            code
            detail)
      }
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
         { blocker_class = Blocked_by_provider_runtime_error
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
         { blocker_class = Blocked_by_provider_runtime_error
         ; summary = lazy (Printf.sprintf "Provider runtime error (%s): %s" code detail)
         })
  | Keeper_registry.Official_client_recovery_required recovery ->
    Some
      { blocker_class = Blocked_by_official_client_recovery
      ; summary = lazy (Keeper_internal_error.official_client_recovery_summary recovery)
      }
  | Keeper_registry.Turn_configuration_error { code; field; detail } ->
    Some
      { blocker_class = Blocked_by_turn_configuration_error
      ; summary = lazy (
          Printf.sprintf
            "Keeper configuration error (%s%s): %s; operator configuration change is required."
            code
            (Option.fold field ~none:"" ~some:(Printf.sprintf " field=%s"))
            detail)
      }
  | Keeper_registry.Fiber_unresolved _ ->
    Some
      { blocker_class = Blocked_by_unresolved_fiber
      ; summary =
          Lazy.from_val
            "Keeper fiber did not resolve a terminal outcome; supervisor cleanup is \
             required."
      }
  | Keeper_registry.Exception detail ->
    Some
      { blocker_class = Blocked_by_exception
      ; summary = lazy (Printf.sprintf "Keeper runtime exception: %s" detail)
      }
  | Keeper_registry.Operator_interrupt ->
    Some
      { blocker_class = Blocked_by_operator_interrupt
      ; summary = lazy ("Current turn was cancelled by explicit operator request.")
      }
;;
