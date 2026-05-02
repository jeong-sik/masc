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

type transition_violation = {
  from_state : string;
  to_state : string;
  reason : string;
}

let same_tla_state a b =
  String.equal (to_tla_symbol a) (to_tla_symbol b)

let same_observable_state a b =
  String.equal (turn_state_label a) (turn_state_label b)

(** Full orthogonal FSM state: the pair of [turn_state] and the
    [stop_signaled] boolean, modelling the two independent variables
    from [KeeperTurnFSM.tla] line 59.

    [stop_signaled] is orthogonal to [turn_state]: the supervisor can
    raise it at any point while the turn is active, and it is the only
    variable changed by [SupervisorRequestsStop].  Tracking it here
    lets [classify_fsm_transition] enforce the invariant that every
    forward transition preserves [stop_signaled = false] and that
    [HonorStopSignal] only fires when [stop_signaled = true]. *)
type fsm_state = {
  turn_state : turn_state;
  stop_signaled : bool;
}

let make_fsm_state ?(stop_signaled = false) turn_state =
  { turn_state; stop_signaled }

(** [classify_fsm_transition ~from_state ~to_state] is the orthogonal
    variant of [classify_transition]: it inspects both [turn_state] and
    [stop_signaled], matching the TLA+ spec exactly.

    Key differences from [classify_transition]:
    - [SupervisorRequestsStop] requires [from_state.stop_signaled = false]
      and [to_state.stop_signaled = true] with the same [turn_state].
    - [HonorStopSignal] requires [from_state.stop_signaled = true].
    - Every other forward transition enforces
      [from_state.stop_signaled = false] and
      [to_state.stop_signaled = false] ([UNCHANGED stop_signaled] in the
      spec's [~stop_signaled] pre-condition branches). *)
let classify_fsm_transition ~from_state ~to_state =
  let fs = from_state.turn_state in
  let ts = to_state.turn_state in
  let ss_from = from_state.stop_signaled in
  let ss_to = to_state.stop_signaled in
  match fs, ts with
  (* SupervisorRequestsStop: stop_signaled flips false→true,
     turn_state is UNCHANGED and must be active.
     The wildcard [_, _] intentionally matches any active state pair
     where [same_tla_state fs ts] holds — the turn_state is unchanged
     and it is the stop_signaled flip that distinguishes this action. *)
  | _, _
    when is_active fs
         && same_tla_state fs ts
         && not ss_from
         && ss_to ->
      Some SupervisorRequestsStop
  (* HonorStopSignal: stop_signaled must already be true; active→cancelled.
     stop_signaled is UNCHANGED (remains true). *)
  | _, Cancelled _
    when is_active fs && ss_from && ss_to ->
      Some HonorStopSignal
  (* TerminalStutter: terminal, same observable state, all UNCHANGED. *)
  | _, _
    when is_terminal fs
         && is_terminal ts
         && same_observable_state fs ts
         && Bool.equal ss_from ss_to ->
      Some TerminalStutter
  (* All forward transitions below require ~stop_signaled precondition
     and UNCHANGED stop_signaled postcondition per the TLA+ spec. *)
  | Idle, Phase_gating
    when not ss_from && not ss_to ->
      Some StartTurn
  | Phase_gating, Done
    when not ss_from && not ss_to ->
      Some PhaseGateSkip
  | Phase_gating, Cascade_routing
    when not ss_from && not ss_to ->
      Some PhaseGateOk
  | Cascade_routing, Awaiting_provider
    when not ss_from && not ss_to ->
      Some CascadeRouted
  | Cascade_routing, Failed (Failure_cascade_unavailable _)
    when not ss_from && not ss_to ->
      Some CascadeUnavailable
  | Awaiting_provider, Streaming
    when not ss_from && not ss_to ->
      Some ProviderResponded
  | Awaiting_provider, Cancelled Cancelled_provider_timeout
    when not ss_from && not ss_to ->
      Some ProviderTimeout
  | Streaming, Awaiting_tool_result
    when not ss_from && not ss_to ->
      Some StreamYieldsTool
  | Awaiting_tool_result, Streaming
    when not ss_from && not ss_to ->
      Some ToolReturned
  | Streaming, Completing
    when not ss_from && not ss_to ->
      Some StreamComplete
  | Completing, Done
    when not ss_from && not ss_to ->
      Some ContractOk
  | Completing, Failed (Failure_tool_contract_violation _)
    when not ss_from && not ss_to ->
      Some ContractViolation
  | Completing, Failed (Failure_receipt_lost _)
    when not ss_from && not ss_to ->
      Some ReceiptLost
  | _, Failed _
    when is_active fs && not ss_from && not ss_to ->
      Some GenericFail
  | _ -> None

let assert_fsm_transition_allowed ~from_state ~to_state =
  match classify_fsm_transition ~from_state ~to_state with
  | Some action -> Ok action
  | None ->
      Error
        {
          from_state = to_tla_symbol from_state.turn_state;
          to_state = to_tla_symbol to_state.turn_state;
          reason = "not_in_keeper_turn_fsm_next";
        }

let classify_transition ~from_state ~to_state =
  match from_state, to_state with
  | Idle, Phase_gating -> Some StartTurn
  | Phase_gating, Done -> Some PhaseGateSkip
  | Phase_gating, Cascade_routing -> Some PhaseGateOk
  | Cascade_routing, Awaiting_provider -> Some CascadeRouted
  | Cascade_routing, Failed (Failure_cascade_unavailable _) ->
      Some CascadeUnavailable
  | Awaiting_provider, Streaming -> Some ProviderResponded
  | Awaiting_provider, Cancelled Cancelled_provider_timeout ->
      Some ProviderTimeout
  | Streaming, Awaiting_tool_result -> Some StreamYieldsTool
  | Awaiting_tool_result, Streaming -> Some ToolReturned
  | Streaming, Completing -> Some StreamComplete
  | Completing, Done -> Some ContractOk
  | Completing, Failed (Failure_tool_contract_violation _) ->
      Some ContractViolation
  | Completing, Failed (Failure_receipt_lost _) -> Some ReceiptLost
  | _, Failed _ when is_active from_state -> Some GenericFail
  | _, Cancelled _ when is_active from_state -> Some HonorStopSignal
  | _, _ when is_active from_state && same_tla_state from_state to_state ->
      Some SupervisorRequestsStop
  | _, _
    when is_terminal from_state && is_terminal to_state
         && same_observable_state from_state to_state ->
      Some TerminalStutter
  | _ -> None

let assert_transition_allowed ~from_state ~to_state =
  match classify_transition ~from_state ~to_state with
  | Some action -> Ok action
  | None ->
      Error
        {
          from_state = to_tla_symbol from_state;
          to_state = to_tla_symbol to_state;
          reason = "not_in_keeper_turn_fsm_next";
        }

let guard_transition ~keeper_name ~turn_id ~from_state ~to_state =
  match assert_transition_allowed ~from_state ~to_state with
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

let emit_transition ~keeper_name ~turn_id ?prev state =
  let prev_label =
    match prev with
    | Some s -> turn_state_label s
    | None -> "-"
  in
  let classified =
    match prev with
    | Some from_state -> classify_transition ~from_state ~to_state:state
    | None -> None
  in
  (match prev with
   | Some from_state ->
       guard_transition ~keeper_name ~turn_id ~from_state ~to_state:state
   | None -> ());
  let state_label = turn_state_label state in
  let action_label =
    match classified with
    | Some action -> transition_action_label action
    | None -> "unknown"
  in
  Log.Keeper.info ~keeper_name ~turn_id
    "[fsm:transition] %s -> %s action=%s" prev_label state_label action_label;
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
