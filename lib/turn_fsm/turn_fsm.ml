(* Pure Turn FSM — the agent turn-cycle state machine, independent of Keeper.

   Carved out of lib/keeper/keeper_turn_fsm.ml so the FSM (states + transition
   matrix) is a neutral library that Keeper *uses*, not a module fused into the
   keeper. The keeper-side glue (telemetry/audit/metrics emission) stays in
   lib/keeper/keeper_turn_fsm.ml, which `include`s this module + supplies an
   [emit_transition] over it.

   Dependency direction: Keeper -> Turn, never the reverse. This module has zero
   Keeper_* references (deps: Masc_domain from masc_types, ppx_tla, stdlib).

   Formal contract: specs/keeper-turn-fsm/KeeperTurnFSM.tla. The [@tla.*] /
   [@@deriving tla] / [@@fsm_guard] annotations bind each state and the
   transition matrix to that spec; test_keeper_turn_fsm_tla_parity verifies
   parity, so this library can be tlc-checked independently of the driver. *)

type cancel_reason =
  | Cancelled_supervisor_stop
  | Cancelled_phase_gate_close
  | Cancelled_provider_timeout
  | Cancelled_fleet_shutdown
  | Cancelled_input_required

type failure_reason =
  | Failure_runtime_unavailable of {
      base : string;
      resolved : string option;
    }
  | Failure_no_capable_provider of {
      runtime_id : string;
      detail : string;
    }
  | Failure_provider_error of { kind : string; detail : string }
  | Failure_receipt_lost of {
      primary_error : string;
      fallback_path : string option;
    }
  | Failure_runtime_error of string
  | Failure_unexpected_exception of {
      exn : string;
      backtrace : string option;
    }

type _ turn_state =
  | Idle : [`Idle] turn_state [@tla.idle]
  | Phase_gating : [`Phase_gating] turn_state [@tla.active]
  | Runtime_routing : [`Runtime_routing] turn_state [@tla.active]
  | Awaiting_provider : [`Awaiting_provider] turn_state [@tla.active]
  | Streaming : [`Streaming] turn_state [@tla.active]
  | Awaiting_tool_result : [`Awaiting_tool_result] turn_state [@tla.symbol "awaiting_tool"] [@tla.active]
  | Completing : [`Completing] turn_state [@tla.active]
  | Done : [`Done] turn_state [@tla.terminal]
  | Failed : failure_reason -> [`Failed] turn_state [@tla.terminal]
  | Cancelled : cancel_reason -> [`Cancelled] turn_state [@tla.terminal]

module Tla_symbol = struct
  type t =
    | Idle [@tla.idle]
    | Phase_gating [@tla.active]
    | Runtime_routing [@tla.active]
    | Awaiting_provider [@tla.active]
    | Streaming [@tla.active]
    | Awaiting_tool_result [@tla.symbol "awaiting_tool"] [@tla.active]
    | Completing [@tla.active]
    | Done [@tla.terminal]
    | Failed of failure_reason [@tla.terminal]
    | Cancelled of cancel_reason [@tla.terminal]
  [@@deriving tla]
end

let tla_symbol_variant : type a. a turn_state -> Tla_symbol.t = function
  | Idle -> Tla_symbol.Idle
  | Phase_gating -> Tla_symbol.Phase_gating
  | Runtime_routing -> Tla_symbol.Runtime_routing
  | Awaiting_provider -> Tla_symbol.Awaiting_provider
  | Streaming -> Tla_symbol.Streaming
  | Awaiting_tool_result -> Tla_symbol.Awaiting_tool_result
  | Completing -> Tla_symbol.Completing
  | Done -> Tla_symbol.Done
  | Failed reason -> Tla_symbol.Failed reason
  | Cancelled reason -> Tla_symbol.Cancelled reason

let to_tla_symbol state = Tla_symbol.to_tla_symbol (tla_symbol_variant state)

let all_symbols = Tla_symbol.all_symbols
let active_symbols = Tla_symbol.active_symbols
let terminal_symbols = Tla_symbol.terminal_symbols
let idle_symbols = Tla_symbol.idle_symbols

let is_active state = Tla_symbol.is_active (tla_symbol_variant state)
let is_terminal state = Tla_symbol.is_terminal (tla_symbol_variant state)
let is_idle state = Tla_symbol.is_idle (tla_symbol_variant state)

let cancel_reason_label = function
  | Cancelled_supervisor_stop -> "supervisor_stop"
  | Cancelled_phase_gate_close -> "phase_gate_close"
  | Cancelled_provider_timeout -> "provider_timeout"
  | Cancelled_fleet_shutdown -> "fleet_shutdown"
  | Cancelled_input_required -> "input_required"

let failure_reason_label = function
  | Failure_runtime_unavailable _ -> "runtime_unavailable"
  | Failure_no_capable_provider _ -> "no_capable_provider"
  | Failure_provider_error _ -> "provider_error"
  | Failure_receipt_lost _ -> "receipt_lost"
  | Failure_runtime_error _ -> "runtime_error"
  | Failure_unexpected_exception _ -> "unexpected_exception"

let turn_state_label : type a. a turn_state -> string = function
  | Failed reason ->
      to_tla_symbol (Failed reason) ^ ":" ^ failure_reason_label reason
  | Cancelled reason ->
      to_tla_symbol (Cancelled reason) ^ ":" ^ cancel_reason_label reason
  | state -> to_tla_symbol state

let pp_cancel_reason fmt r =
  Format.pp_print_string fmt (cancel_reason_label r)

let pp_failure_reason fmt = function
  | Failure_runtime_unavailable { base; resolved } ->
      Format.fprintf fmt "runtime_unavailable(base=%s,resolved=%s)"
        base
        (Option.value resolved ~default:"-")
  | Failure_no_capable_provider { runtime_id; detail } ->
      Format.fprintf fmt "no_capable_provider(runtime=%s,detail=%s)"
        runtime_id detail
  | Failure_provider_error { kind; detail } ->
      Format.fprintf fmt "provider_error(kind=%s,detail=%s)" kind detail
  | Failure_receipt_lost { primary_error; fallback_path } ->
      Format.fprintf fmt "receipt_lost(err=%s,fallback=%s)"
        primary_error
        (Option.value fallback_path ~default:"-")
  | Failure_runtime_error msg ->
      Format.fprintf fmt "runtime_error(%s)" msg
  | Failure_unexpected_exception { exn; _ } ->
      Format.fprintf fmt "unexpected_exception(%s)" exn

let pp_turn_state fmt (s : _ turn_state) =
  Format.pp_print_string fmt (turn_state_label s)

type transition_action =
  | StartTurn
  | PhaseGateSkip
  | PhaseGateOk
  | RuntimeRouted
  | RuntimeUnavailable
  | ProviderResponded
  | ProviderTimeout
  | StreamYieldsTool
  | ToolReturned
  | StreamComplete
  | FinishTurn
  | ReceiptLost
  | NoToolCapableProvider
  | ProviderError
  | GenericFail
  | SupervisorRequestsStop
  | HonorStopSignal
  | TerminalStutter

let transition_action_label = function
  | StartTurn -> "StartTurn"
  | PhaseGateSkip -> "PhaseGateSkip"
  | PhaseGateOk -> "PhaseGateOk"
  | RuntimeRouted -> "RuntimeRouted"
  | RuntimeUnavailable -> "RuntimeUnavailable"
  | ProviderResponded -> "ProviderResponded"
  | ProviderTimeout -> "ProviderTimeout"
  | StreamYieldsTool -> "StreamYieldsTool"
  | ToolReturned -> "ToolReturned"
  | StreamComplete -> "StreamComplete"
  | FinishTurn -> "FinishTurn"
  | ReceiptLost -> "ReceiptLost"
  | NoToolCapableProvider -> "NoToolCapableProvider"
  | ProviderError -> "ProviderError"
  | GenericFail -> "GenericFail"
  | SupervisorRequestsStop -> "SupervisorRequestsStop"
  | HonorStopSignal -> "HonorStopSignal"
  | TerminalStutter -> "TerminalStutter"

type transition_context = {
  stop_signaled_before : bool;
  stop_signaled_after : bool;
}

let default_transition_context =
  { stop_signaled_before = false; stop_signaled_after = false }

type transition_violation = {
  from_state : string;
  to_state : string;
  reason : string;
}

let same_tla_state a b =
  String.equal (to_tla_symbol a) (to_tla_symbol b)

let same_observable_state a b =
  String.equal (turn_state_label a) (turn_state_label b)


type any_state = Any : _ turn_state -> any_state

let any_state_label (Any s) = turn_state_label s
let pp_any_state fmt (Any s) = pp_turn_state fmt s

let classify_transition ?ctx ~(from_state: _ turn_state) ~(to_state: _ turn_state) () =
  let stop_signaled_before =
    match ctx with
    | None -> default_transition_context.stop_signaled_before
    | Some ctx -> ctx.stop_signaled_before
  in
  let stop_raised =
    match ctx with
    | None -> false
    | Some ctx -> (not ctx.stop_signaled_before) && ctx.stop_signaled_after
  in
  let stop_unchanged =
    match ctx with
    | None -> true
    | Some ctx -> Bool.equal ctx.stop_signaled_before ctx.stop_signaled_after
  in
  let honor_stop_signal_allowed =
    match ctx with
    | None -> true
    | Some ctx -> ctx.stop_signaled_before
  in
  let supervisor_requests_stop_allowed =
    match ctx with
    | None -> true
    | Some _ -> stop_raised
  in
  match Any from_state, Any to_state with
  | Any Idle, Any Phase_gating when not stop_signaled_before ->
      Some StartTurn
  | Any Phase_gating, Any Done when not stop_signaled_before ->
      Some PhaseGateSkip
  | Any Phase_gating, Any Runtime_routing when not stop_signaled_before ->
      Some PhaseGateOk
  | Any Runtime_routing, Any Awaiting_provider when not stop_signaled_before ->
      Some RuntimeRouted
  | Any Runtime_routing, Any (Failed (Failure_runtime_unavailable _))
    when not stop_signaled_before ->
      Some RuntimeUnavailable
  | Any Runtime_routing, Any (Failed (Failure_no_capable_provider _))
    when not stop_signaled_before ->
      Some NoToolCapableProvider
  | Any Runtime_routing, Any (Failed (Failure_provider_error _))
    when not stop_signaled_before ->
      Some ProviderError
  | Any Awaiting_provider, Any Streaming when not stop_signaled_before ->
      Some ProviderResponded
  | Any Awaiting_provider, Any (Cancelled Cancelled_provider_timeout)
    when not stop_signaled_before ->
      Some ProviderTimeout
  | Any Streaming, Any Awaiting_tool_result when not stop_signaled_before ->
      Some StreamYieldsTool
  | Any Awaiting_tool_result, Any Streaming when not stop_signaled_before ->
      Some ToolReturned
  | Any Streaming, Any Completing when not stop_signaled_before ->
      Some StreamComplete
  | Any Streaming, Any (Failed (Failure_receipt_lost _))
    when not stop_signaled_before ->
      Some ReceiptLost
  | Any Streaming, Any (Failed (Failure_provider_error _))
    when not stop_signaled_before ->
      Some ProviderError
  | Any Streaming, Any (Cancelled Cancelled_provider_timeout)
    when not stop_signaled_before ->
      Some ProviderTimeout
  | Any Completing, Any Done when not stop_signaled_before ->
      Some FinishTurn
  | Any Completing, Any (Failed (Failure_receipt_lost _))
    when not stop_signaled_before ->
      Some ReceiptLost
  | _, Any (Failed _) when is_active from_state -> Some GenericFail
  | _, Any (Cancelled _) when is_active from_state && honor_stop_signal_allowed ->
      Some HonorStopSignal
  | _, _
    when supervisor_requests_stop_allowed
         && is_active from_state
         && same_tla_state from_state to_state ->
      Some SupervisorRequestsStop
  | _, _
    when is_terminal from_state
         && is_terminal to_state
         && stop_unchanged
         && same_observable_state from_state to_state ->
      Some TerminalStutter
  | _ -> None

let assert_transition_allowed ?ctx ~(from_state: _ turn_state) ~(to_state: _ turn_state) () =
  match classify_transition ?ctx ~from_state ~to_state () with
  | Some action -> Ok action
  | None ->
      Error
        {
          from_state = to_tla_symbol from_state;
          to_state = to_tla_symbol to_state;
          reason = "not_in_keeper_turn_fsm_next";
        }

(* NOTE: [require_active_state] is NOT here — its [@@fsm_guard] ppx_tla
   expansion injects a call to [Keeper_fsm_guard_runtime], which would couple
   this pure library to the keeper. It stays in the keeper-side shim
   ([Keeper_turn_fsm]) alongside the other emission glue. The pure FSM
   (states + transition matrix) is the entire contents of this module. *)
