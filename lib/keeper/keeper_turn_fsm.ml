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
  | Idle
  | Phase_gating
  | Cascade_routing
  | Awaiting_provider
  | Streaming
  | Awaiting_tool_result
  | Completing
  | Done
  | Failed of failure_reason
  | Cancelled of cancel_reason

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
  | Idle -> "idle"
  | Phase_gating -> "phase_gating"
  | Cascade_routing -> "cascade_routing"
  | Awaiting_provider -> "awaiting_provider"
  | Streaming -> "streaming"
  | Awaiting_tool_result -> "awaiting_tool_result"
  | Completing -> "completing"
  | Done -> "done"
  | Failed reason ->
      "failed:" ^ failure_reason_label reason
  | Cancelled reason ->
      "cancelled:" ^ cancel_reason_label reason

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

let emit_transition ~keeper_name ~turn_id ?prev state =
  let prev_label =
    match prev with
    | Some s -> turn_state_label s
    | None -> "-"
  in
  let state_label = turn_state_label state in
  Log.Keeper.info ~keeper_name ~turn_id
    "[fsm:transition] %s -> %s" prev_label state_label
