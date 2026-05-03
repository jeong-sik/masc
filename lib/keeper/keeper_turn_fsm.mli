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
val to_tla_symbol : _ turn_state -> string
val turn_state_label : _ turn_state -> string

val pp_cancel_reason : Format.formatter -> cancel_reason -> unit
val pp_failure_reason : Format.formatter -> failure_reason -> unit
val pp_turn_state : Format.formatter -> _ turn_state -> unit

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

type transition_context = {
  stop_signaled_before : bool;
  stop_signaled_after : bool;
}
(** Orthogonal stop-signal state for a transition.

    Mirrors the TLA+ variable [stop_signaled] in
    [specs/keeper-turn-fsm/KeeperTurnFSM.tla] (line 59).  Forward
    transitions require [stop_signaled_before = false];
    [SupervisorRequestsStop] requires [(not before) && after]. *)

val default_transition_context : transition_context
(** Both fields [false] — used when stop-signal tracking is not
    available at the call site. *)

type transition_violation = {
  from_state : string;
  to_state : string;
  reason : string;
}

val classify_transition :
  ?ctx:transition_context ->
  from_state:_ turn_state ->
  to_state:_ turn_state ->
  unit ->
  transition_action option
(** Return the TLA+ action represented by an OCaml state edge, if the
    edge is allowed by the keeper-turn FSM contract.

    When [?ctx] is provided, forward transitions guard on
    [stop_signaled_before = false] (matching the TLA+ [~stop_signaled]
    precondition on every forward action) and [SupervisorRequestsStop]
    requires [stop_signaled] to transition from [false] to [true]
    (matching the TLA+ [~stop_signaled /\ stop_signaled'] guard).

    When [?ctx] is omitted, the behavior is backward-compatible: forward
    transitions have no stop-signal guard, and [SupervisorRequestsStop]
    falls back to the same-state heuristic. *)

val assert_transition_allowed :
  ?ctx:transition_context ->
  from_state:_ turn_state ->
  to_state:_ turn_state ->
  unit ->
  (transition_action, transition_violation) result

val require_active_state : _ turn_state -> (unit, Types.masc_error) result
(** Identity on [s]; runtime-asserts that [s] is not a terminal state
    ([Done], [Failed _], [Cancelled _]).

    Cycle 12 / Tier I3 smoke test for the [@@fsm_guard "..."] PPX:
    this is the first real-module use that the rewriter operates on.
    The assert lands in the function body via [ppx_tla] so the runtime
    cost is one match per call. Adopt at sites that enter execution
    paths assuming the turn is still in flight. *)

val emit_transition :
  ?ctx:transition_context ->
  keeper_name:string ->
  turn_id:int ->
  ?prev:_ turn_state ->
  _ turn_state ->
  unit
(** Emit a structured FSM transition log line.

    Step 4b kicks off the call-site adoption stack: this is an
    observe-only secondary emit alongside the existing receipt
    path.  The runtime branch shape is unchanged; the line
    surfaces in [bin/masc-trace] via the [turn_id] correlator
    wired in Step 0a (#11154 / #11156 / #11159) so an operator
    can see the state the runtime *intended* without parsing
    the receipt JSON.

    The line format is
    [\[fsm:transition\] <prev> -> <state> action=<action> stop_before=.. stop_after=..];
    a missing [?prev] renders as ["-"].  Stop-signal fields are
    emitted only when [?ctx] is provided.  Stable for operator
    regex parsing and pinned by the [test_keeper_turn_fsm_emit]
    sentinel so a future signature drift fails the build. *)

type any_state = Any : _ turn_state -> any_state
val any_state_label : any_state -> string
val pp_any_state : Format.formatter -> any_state -> unit

val all_symbols : string list
val active_symbols : string list
val terminal_symbols : string list
val idle_symbols : string list

val is_active : _ turn_state -> bool
val is_terminal : _ turn_state -> bool
val is_idle : _ turn_state -> bool
