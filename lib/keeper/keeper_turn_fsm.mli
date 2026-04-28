(** Typed FSM vocabulary for keeper turn lifecycle.

    Step 4a of the bloodflow restoration plan introduces the
    state / failure / cancel-reason ADTs only.  The transition
    function with telemetry emission is left to a follow-up
    stack so the type surface lands additively first.

    Cross-reference: [docs/keeper-turn-lifecycle.md] (Step 8 diagram). *)

type cancel_reason =
  | Cancelled_supervisor_stop
      (** Operator/supervisor requested keeper shutdown. *)
  | Cancelled_phase_gate_close
      (** Phase transition closed an in-flight turn. *)
  | Cancelled_provider_timeout
      (** Underlying provider (CLI subprocess or HTTP) timed out
          past the cooperative-cancel deadline. *)
  | Cancelled_fleet_shutdown
      (** Process is exiting; no more turns will be dispatched. *)

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
      (** Pre-dispatch livelock guard ([Keeper_turn_livelock])
          rejected this turn because the keeper is stuck in a
          loop on the same task.  Distinct from [runtime_error]
          so PromQL can chart livelock incidence on its own. *)
  | Failure_runtime_error of string
  | Failure_unexpected_exception of {
      exn : string;
      backtrace : string option;
    }

(** Turn FSM states.  Mirrors the lanes in
    [docs/keeper-turn-lifecycle.md]; the runtime [run_keeper_cycle]
    is currently implicit across multiple files and Step 4b will
    introduce explicit transitions. *)
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

val cancel_reason_label : cancel_reason -> string
val failure_reason_label : failure_reason -> string
val turn_state_label : turn_state -> string

val tla_state_symbol : turn_state -> string
(** Project [turn_state] to the symbol used in the TLA+
    [TurnStateSet] of [specs/keeper-turn-fsm/KeeperTurnFSM.tla].

    Distinct from [turn_state_label]: the runtime label
    ([Awaiting_tool_result -> "awaiting_tool_result"]) is operator-
    facing and stable for trace regex; the TLA+ symbol
    ([Awaiting_tool_result -> "awaiting_tool"]) follows the spec's
    abbreviated naming.  The mapping was previously documented only
    in a TLA+ comment (KeeperTurnFSM.tla:32) and not enforceable.

    Pinned by [test_keeper_turn_fsm_tla_alignment]: the set of
    symbols produced by this function must equal [TurnStateSet],
    so a spec rename or constructor addition fails the build. *)

val all_turn_state_symbols : string list
(** Sorted set of TLA+ symbols emitted by [tla_state_symbol] over
    every [turn_state] constructor.  Used by the alignment test to
    cross-check against [TurnStateSet] in the spec file. *)

val pp_cancel_reason : Format.formatter -> cancel_reason -> unit
val pp_failure_reason : Format.formatter -> failure_reason -> unit
val pp_turn_state : Format.formatter -> turn_state -> unit

val emit_transition :
  keeper_name:string ->
  turn_id:int ->
  ?prev:turn_state ->
  turn_state ->
  unit
(** Emit a structured FSM transition log line.

    Step 4b kicks off the call-site adoption stack: this is an
    observe-only secondary emit alongside the existing receipt
    path.  The runtime branch shape is unchanged; the line
    surfaces in [bin/masc-trace] via the [turn_id] correlator
    wired in Step 0a (#11154 / #11156 / #11159) so an operator
    can see the state the runtime *intended* without parsing
    the receipt JSON.

    The line format is [\[fsm:transition\] <prev> -> <state>];
    a missing [?prev] renders as ["-"].  Stable for operator
    regex parsing and pinned by the [test_keeper_turn_fsm_emit]
    sentinel so a future signature drift fails the build. *)
