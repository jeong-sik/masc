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
(** TLA+ symbol mapping derived by [ppx_tla].

    [to_tla_symbol] / [all_symbols] match [TurnStateSet], while
    [active_symbols] / [terminal_symbols] and the generated
    [is_active] / [is_terminal] predicates match [ActiveStateSet] and
    [TerminalStateSet] in [specs/keeper-turn-fsm/KeeperTurnFSM.tla]
    (verified by [test_keeper_turn_fsm_tla_parity]).

    [@tla.symbol "awaiting_tool"] on [Awaiting_tool_result] covers the
    OCaml-vs-TLA+ naming difference without renaming either side. *)

val cancel_reason_label : cancel_reason -> string
val failure_reason_label : failure_reason -> string
val turn_state_label : turn_state -> string

val pp_cancel_reason : Format.formatter -> cancel_reason -> unit
val pp_failure_reason : Format.formatter -> failure_reason -> unit
val pp_turn_state : Format.formatter -> turn_state -> unit

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
(** Runtime image of [KeeperTurnFSM.tla] [Next] actions.

    [GenericFail] is the OCaml-side structured-failure extension for
    active-state failures whose carrier is more specific than the compact
    TLA projection. *)

val transition_action_label : transition_action -> string

type transition_violation = {
  from_state : string;
  to_state : string;
  reason : string;
}

(** Full orthogonal FSM state pairing [turn_state] with the
    [stop_signaled] boolean from [KeeperTurnFSM.tla] line 59.

    [stop_signaled] is independent of [turn_state]: the supervisor can
    raise it at any point while the turn is active.  Tracking it here
    allows [classify_fsm_transition] to enforce that every forward
    transition preserves [stop_signaled = false] and that
    [HonorStopSignal] only fires when [stop_signaled = true]. *)
type fsm_state = {
  turn_state : turn_state;
  stop_signaled : bool;
}

val make_fsm_state : ?stop_signaled:bool -> turn_state -> fsm_state
(** Construct an [fsm_state].  [stop_signaled] defaults to [false],
    matching [Init] in the TLA+ spec. *)

val classify_fsm_transition :
  from_state:fsm_state ->
  to_state:fsm_state ->
  transition_action option
(** Orthogonal variant of [classify_transition]: inspects both
    [turn_state] and [stop_signaled], matching the TLA+ spec exactly.

    Key differences from [classify_transition]:
    - [SupervisorRequestsStop] requires [from_state.stop_signaled = false]
      and [to_state.stop_signaled = true] with the same [turn_state].
    - [HonorStopSignal] requires [from_state.stop_signaled = true].
    - Every other forward transition enforces
      [from_state.stop_signaled = false] and
      [to_state.stop_signaled = false]
      ([UNCHANGED stop_signaled] / [~stop_signaled] precondition). *)

val assert_fsm_transition_allowed :
  from_state:fsm_state ->
  to_state:fsm_state ->
  (transition_action, transition_violation) result
(** Orthogonal variant of [assert_transition_allowed] that uses the
    full [fsm_state] (including [stop_signaled]) to validate transitions. *)

val classify_transition :
  from_state:turn_state ->
  to_state:turn_state ->
  transition_action option
(** Return the TLA+ action represented by an OCaml state edge, if the
    edge is allowed by the keeper-turn FSM contract.

    This function inspects only [turn_state]; use
    [classify_fsm_transition] when [stop_signaled] is also tracked. *)

val assert_transition_allowed :
  from_state:turn_state ->
  to_state:turn_state ->
  (transition_action, transition_violation) result

val require_active_state : turn_state -> turn_state
(** Identity on [s]; runtime-asserts that [s] is not a terminal state
    ([Done], [Failed _], [Cancelled _]).

    Cycle 12 / Tier I3 smoke test for the [@@fsm_guard "..."] PPX:
    this is the first real-module use that the rewriter operates on.
    The assert lands in the function body via [ppx_tla] so the runtime
    cost is one match per call. Adopt at sites that enter execution
    paths assuming the turn is still in flight. *)

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
