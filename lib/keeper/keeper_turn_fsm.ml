type cancel_reason =
  | Cancelled_supervisor_stop
  | Cancelled_phase_gate_close
  | Cancelled_provider_timeout
  | Cancelled_fleet_shutdown

type failure_reason =
  | Failure_cascade_unavailable of {
      base : string;
      resolved : string option;
    }
  | Failure_provider_error of { kind : string; detail : string }
  | Failure_tool_contract_violation of { reason_code : string }
  | Failure_receipt_lost of {
      primary_error : string;
      fallback_path : string option;
    }
  | Failure_turn_livelock_blocked of { reason : string }
  | Failure_runtime_error of string
  | Failure_unexpected_exception of {
      exn : string;
      backtrace : string option;
    }

type _ turn_state =
  | Idle : [`Idle] turn_state [@tla.idle]
  | Phase_gating : [`Phase_gating] turn_state [@tla.active]
  | Cascade_routing : [`Cascade_routing] turn_state [@tla.active]
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
    | Cascade_routing [@tla.active]
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
  | Cascade_routing -> Tla_symbol.Cascade_routing
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

let failure_reason_label = function
  | Failure_cascade_unavailable _ -> "cascade_unavailable"
  | Failure_provider_error _ -> "provider_error"
  | Failure_tool_contract_violation _ -> "tool_contract_violation"
  | Failure_receipt_lost _ -> "receipt_lost"
  | Failure_turn_livelock_blocked _ -> "turn_livelock_blocked"
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
  | Failure_cascade_unavailable { base; resolved } ->
      Format.fprintf fmt "cascade_unavailable(base=%s,resolved=%s)"
        base
        (Option.value resolved ~default:"-")
  | Failure_provider_error { kind; detail } ->
      Format.fprintf fmt "provider_error(kind=%s,detail=%s)" kind detail
  | Failure_tool_contract_violation { reason_code } ->
      Format.fprintf fmt "tool_contract_violation(%s)" reason_code
  | Failure_receipt_lost { primary_error; fallback_path } ->
      Format.fprintf fmt "receipt_lost(err=%s,fallback=%s)"
        primary_error
        (Option.value fallback_path ~default:"-")
  | Failure_turn_livelock_blocked { reason } ->
      Format.fprintf fmt "turn_livelock_blocked(%s)" reason
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
  | CascadeRouted
  | CascadeUnavailable
  | ProviderResponded
  | ProviderTimeout
  | StreamYieldsTool
  | ToolReturned
  | StreamComplete
  | ContractOk
  | ContractViolation
  | ReceiptLost
  | GenericFail
  | SupervisorRequestsStop
  | HonorStopSignal
  | TerminalStutter

let transition_action_label = function
  | StartTurn -> "StartTurn"
  | PhaseGateSkip -> "PhaseGateSkip"
  | PhaseGateOk -> "PhaseGateOk"
  | CascadeRouted -> "CascadeRouted"
  | CascadeUnavailable -> "CascadeUnavailable"
  | ProviderResponded -> "ProviderResponded"
  | ProviderTimeout -> "ProviderTimeout"
  | StreamYieldsTool -> "StreamYieldsTool"
  | ToolReturned -> "ToolReturned"
  | StreamComplete -> "StreamComplete"
  | ContractOk -> "ContractOk"
  | ContractViolation -> "ContractViolation"
  | ReceiptLost -> "ReceiptLost"
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
  | Any Phase_gating, Any Cascade_routing when not stop_signaled_before ->
      Some PhaseGateOk
  | Any Cascade_routing, Any Awaiting_provider when not stop_signaled_before ->
      Some CascadeRouted
  | Any Cascade_routing, Any (Failed (Failure_cascade_unavailable _))
    when not stop_signaled_before ->
      Some CascadeUnavailable
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
  | Any Completing, Any Done when not stop_signaled_before ->
      Some ContractOk
  | Any Completing, Any (Failed (Failure_tool_contract_violation _))
    when not stop_signaled_before ->
      Some ContractViolation
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

let guard_transition ?ctx ~keeper_name ~turn_id ~from_state ~to_state () =
  match assert_transition_allowed ?ctx ~from_state ~to_state () with
  | Ok _ -> ()
  | Error violation ->
      (* Log first: [wrap_unit] catches [Assert_failure] only to bump the
         Prometheus counter, then re-raises. Anything sequenced after
         [wrap_unit] would never run, so the diagnostic warn has to
         precede it for operators to see *which* transition violated. *)
      Log.Keeper.warn ~keeper_name ~turn_id
        "[fsm:transition:violation] %s -> %s (%s)"
        violation.from_state violation.to_state violation.reason;
      let stage = violation.from_state ^ "->" ^ violation.to_state in
      Keeper_fsm_guard_runtime.wrap_unit
        ~action:"KeeperTurnFSM.Next"
        ~stage
        (fun () -> assert false)

(* Per-keeper last-transition wallclock, used to record the dwell time
   spent in [prev] state when a transition fires. Single-domain Eio
   means Hashtbl ops are atomic at OCaml level (no preemption inside a
   single op), so no explicit mutex is required. Stale entries left
   behind by terminal transitions are bounded by keeper count. *)
let last_transition_at : (string, float) Hashtbl.t = Hashtbl.create 64

let observe_phase_dwell ~keeper_name ~from_label =
  match Hashtbl.find_opt last_transition_at keeper_name with
  | None -> ()
  | Some prev_at ->
    let now = Unix.gettimeofday () in
    let dwell = Float.max 0.0 (now -. prev_at) in
    (* Cancel-aware: bare [try ... with _ -> ()] would swallow
       [Eio.Cancel.Cancelled] and break switch teardown. *)
    Safe_ops.protect ~default:() (fun () ->
      Prometheus.observe_histogram
        Keeper_metrics.metric_keeper_turn_phase_duration
        ~labels:[ ("keeper", keeper_name); ("from", from_label) ]
        dwell)

let emit_transition ?ctx ~keeper_name ~turn_id ?prev state =
  let prev_label =
    match prev with
    | Some s -> turn_state_label s
    | None -> "-"
  in
  (match prev with
   | Some _ -> observe_phase_dwell ~keeper_name ~from_label:prev_label
   | None -> ());
  Hashtbl.replace last_transition_at keeper_name (Unix.gettimeofday ());
  let classified =
    match prev with
    | Some from_state ->
        classify_transition ?ctx ~from_state ~to_state:state ()
    | None -> None
  in
  (match prev with
   | Some from_state ->
       guard_transition ?ctx ~keeper_name ~turn_id ~from_state ~to_state:state ()
   | None -> ());
  let state_label = turn_state_label state in
  let action_label =
    match classified with
    | Some action -> transition_action_label action
    | None -> "unknown"
  in
  let stop_label =
    match ctx with
    | Some c ->
        Printf.sprintf " stop_before=%b stop_after=%b"
          c.stop_signaled_before c.stop_signaled_after
    | None -> ""
  in
  Log.Keeper.info ~keeper_name ~turn_id
    "[fsm:transition] %s -> %s action=%s%s" prev_label state_label action_label
    stop_label;
  Prometheus.inc_counter Keeper_metrics.metric_keeper_turn_fsm_transitions
    ~labels:
      [ ("from", prev_label);
        ("to", state_label);
        ("action", action_label);
        ("keeper", keeper_name);
      ]
    ()

(* Cycle 12 / Tier I3 smoke test: first real-module use of [@@fsm_guard].

   [require_active_state] is the identity on its argument; the [@@fsm_guard]
   payload is parsed by [ppx_tla] and injected as a runtime [assert] at
   the function body entry. The invariant — turn states that have
   already terminated must not re-enter execution paths — was previously
   only guarded by reviewer-eye inspection of call sites. *)

let require_active_state : type a. a turn_state -> (unit, Masc_domain.masc_error) result = fun s ->
  match s with
  | Done | Failed _ | Cancelled _ ->
      Error
        (Masc_domain.Task (Masc_domain.Task_error.InvalidState
           (Printf.sprintf "Terminal state %s cannot re-enter active paths"
              (turn_state_label s))))
  | _ -> Ok ()
[@@fsm_guard
  "match s with Done | Failed _ | Cancelled _ -> false | _ -> true"]
