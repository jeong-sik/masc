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

type turn_state =
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

let turn_state_label = function
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

let pp_turn_state fmt s =
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

let classify_transition ?(ctx = default_transition_context) ~from_state ~to_state () =
  let stop_raised =
    (not ctx.stop_signaled_before) && ctx.stop_signaled_after
  in
  match from_state, to_state with
  | Idle, Phase_gating when not ctx.stop_signaled_before ->
      Some StartTurn
  | Phase_gating, Done when not ctx.stop_signaled_before ->
      Some PhaseGateSkip
  | Phase_gating, Cascade_routing when not ctx.stop_signaled_before ->
      Some PhaseGateOk
  | Cascade_routing, Awaiting_provider when not ctx.stop_signaled_before ->
      Some CascadeRouted
  | Cascade_routing, Failed (Failure_cascade_unavailable _)
    when not ctx.stop_signaled_before ->
      Some CascadeUnavailable
  | Awaiting_provider, Streaming when not ctx.stop_signaled_before ->
      Some ProviderResponded
  | Awaiting_provider, Cancelled Cancelled_provider_timeout
    when not ctx.stop_signaled_before ->
      Some ProviderTimeout
  | Streaming, Awaiting_tool_result when not ctx.stop_signaled_before ->
      Some StreamYieldsTool
  | Awaiting_tool_result, Streaming when not ctx.stop_signaled_before ->
      Some ToolReturned
  | Streaming, Completing when not ctx.stop_signaled_before ->
      Some StreamComplete
  | Completing, Done when not ctx.stop_signaled_before ->
      Some ContractOk
  | Completing, Failed (Failure_tool_contract_violation _)
    when not ctx.stop_signaled_before ->
      Some ContractViolation
  | Completing, Failed (Failure_receipt_lost _)
    when not ctx.stop_signaled_before ->
      Some ReceiptLost
  | _, Failed _ when is_active from_state -> Some GenericFail
  | _, Cancelled _ when is_active from_state -> Some HonorStopSignal
  | _, _
    when stop_raised
         && is_active from_state
         && same_tla_state from_state to_state ->
      Some SupervisorRequestsStop
  | _, _
    when is_terminal from_state
         && is_terminal to_state
         && same_observable_state from_state to_state ->
      Some TerminalStutter
  | _ -> None

let assert_transition_allowed ?ctx ~from_state ~to_state () =
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
      let stage = violation.from_state ^ "->" ^ violation.to_state in
      Keeper_fsm_guard_runtime.wrap_unit
        ~action:"KeeperTurnFSM.Next"
        ~stage
        (fun () -> assert false);
      Log.Keeper.warn ~keeper_name ~turn_id
        "[fsm:transition:violation] %s -> %s (%s)"
        violation.from_state violation.to_state violation.reason

let emit_transition ?ctx ~keeper_name ~turn_id ?prev state =
  let prev_label =
    match prev with
    | Some s -> turn_state_label s
    | None -> "-"
  in
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
  Prometheus.inc_counter Prometheus.metric_keeper_turn_fsm_transitions
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

let require_active_state s = s
[@@fsm_guard
  "match s with Done | Failed _ | Cancelled _ -> false | _ -> true"]
