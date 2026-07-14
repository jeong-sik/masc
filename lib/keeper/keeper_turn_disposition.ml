(* RFC-0047 PR-1: operator-facing disposition closed sum.

   See [.mli] for the public contract. This file holds the type
   definition, the canonical projection from
   [Keeper_turn_terminal_code], and the wire-format serialisation
   chosen to be byte-for-byte compatible with the strings emitted
   today by [Keeper_turn_terminal.t.code]. *)

module Code = Keeper_turn_terminal_code

type t =
  | Success
  | External_cancel
  | Input_required
  | Turn_wall_clock_timeout
  | Runtime_attempts_exhausted
  | Provider_error of Code.t
  | Unknown of { raw_error : string }

type severity =
  | Ok
  | Warn
  | Bad
  | Unknown_bad

let severity = function
  | Success -> Ok
  | Input_required -> Ok
  | External_cancel
  | Turn_wall_clock_timeout
  | Runtime_attempts_exhausted -> Warn
  | Provider_error _ -> Bad
  | Unknown _ -> Unknown_bad
;;

let summary = function
  | Success -> "turn completed"
  | Input_required -> "agent paused to request human input"
  | External_cancel -> "keeper turn was cancelled before completion"
  | Turn_wall_clock_timeout ->
    "keeper turn hit a stale/no-progress timeout"
  | Runtime_attempts_exhausted ->
    "runtime attempts exhausted; inspect per-attempt root causes"
  | Provider_error code -> Printf.sprintf "keeper turn ended with %s" (Code.to_wire code)
  | Unknown { raw_error = "" } ->
    "keeper turn failed without a classified terminal reason"
  | Unknown { raw_error } -> Printf.sprintf "keeper turn ended with %s" raw_error
;;

let next_action = function
  | Success -> None
  | Input_required -> Some "provide_input_or_decline"
  | External_cancel -> Some "rerun_if_still_relevant"
  | Turn_wall_clock_timeout -> Some "inspect_turn_timeout"
  | Runtime_attempts_exhausted -> Some "inspect_runtime_attempts"
  | Provider_error _ | Unknown _ -> Some "inspect_latest_error"
;;

let to_wire = function
  | Success -> "success"
  | Input_required -> "input_required"
  | External_cancel -> "external_cancel"
  | Turn_wall_clock_timeout -> "turn_wall_clock_timeout"
  | Runtime_attempts_exhausted -> "runtime_attempts_exhausted"
  | Provider_error code -> Code.to_wire code
  | Unknown { raw_error = "" } -> "unknown_error"
  | Unknown { raw_error } -> raw_error
;;

(* Projection from runtime layer to operator layer.

   A runtime cause maps directly to a non-[Provider_error] arm only
   when the runtime classification fully determines the operator
   action. Stale_turn_timeout_* are operator-equivalent to the
   stale/no-progress timeout disposition.
   All other runtime causes are wrapped so the typed cause is
   preserved for diagnostics. *)
let of_termination_code (c : Code.t) : t =
  match c with
  | Code.Healthy -> Success
  | Code.Stale_turn_timeout_idle
  | Code.Stale_turn_timeout_in_turn
  | Code.Stale_turn_timeout_no_progress
  | Code.Stale_turn_timeout_noop -> Turn_wall_clock_timeout
  | Code.Heartbeat_failures
  | Code.Turn_failures
  | Code.Stale_termination_storm
  | Code.Stale_fleet_batch
  | Code.Turn_overflow_failure
  | Code.Operator_interrupt
  | Code.Provider_runtime_error _
  | Code.Fiber_unresolved
  | Code.Exception_unhandled _
  | Code.Sdk_error _ -> Provider_error c
;;

let of_wire wire =
  match wire with
     | "success" -> Success
     | "input_required" -> Input_required
     | "external_cancel" -> External_cancel
     | "turn_wall_clock_timeout" -> Turn_wall_clock_timeout
     | "runtime_attempts_exhausted" -> Runtime_attempts_exhausted
     | "unknown_error" -> Unknown { raw_error = "" }
     | other ->
       (match Code.of_wire other with
        | Some c -> of_termination_code c
        | None -> Unknown { raw_error = other })
;;

let is_success = function
  | Success -> true
  | External_cancel
  | Input_required
  | Turn_wall_clock_timeout
  | Runtime_attempts_exhausted
  | Provider_error _
  | Unknown _ -> false
;;

let equal a b =
  match a, b with
  | Success, Success
  | Input_required, Input_required
  | External_cancel, External_cancel
  | Turn_wall_clock_timeout, Turn_wall_clock_timeout
  | Runtime_attempts_exhausted, Runtime_attempts_exhausted -> true
  | Provider_error a, Provider_error b -> String.equal (Code.to_wire a) (Code.to_wire b)
  | Unknown a, Unknown b -> String.equal a.raw_error b.raw_error
  | ( Success
    | Input_required
    | External_cancel
    | Turn_wall_clock_timeout
    | Runtime_attempts_exhausted
    | Provider_error _
    | Unknown _ ), _ -> false
;;

let pp fmt t = Format.pp_print_string fmt (to_wire t)
