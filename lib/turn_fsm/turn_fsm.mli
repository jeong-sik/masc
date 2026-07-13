(** Pure Turn FSM — the agent turn-cycle state machine, independent of Keeper.

    States, reasons, and the transition matrix only; no telemetry/audit/metrics
    emission (that glue lives in [Keeper_turn_fsm], which [include]s this module).
    Dependency direction is Keeper -> Turn, never the reverse.

    Formal contract: [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. The [@tla.*] /
    [@@deriving tla] annotations bind states + the transition matrix to that
    spec; [test_keeper_turn_fsm_tla_parity] verifies parity. *)

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
  | Cancelled_input_required
      (** Agent paused to request human input (InputRequired). *)

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

(** Turn FSM states.  Mirrors the lanes in
    [docs/keeper-turn-lifecycle.md]. *)
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
(** Runtime image of [KeeperTurnFSM.tla] [Next] actions. *)

val transition_action_label : transition_action -> string

type transition_context = {
  stop_signaled_before : bool;
  stop_signaled_after : bool;
}
(** Orthogonal stop-signal state for a transition.  Mirrors the TLA+ variable
    [stop_signaled] in [specs/keeper-turn-fsm/KeeperTurnFSM.tla]. *)

val default_transition_context : transition_context

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
    edge is allowed by the keeper-turn FSM contract. *)

val assert_transition_allowed :
  ?ctx:transition_context ->
  from_state:_ turn_state ->
  to_state:_ turn_state ->
  unit ->
  (transition_action, transition_violation) result

(* [require_active_state] lives in the keeper-side shim [Keeper_turn_fsm], not
   here: its [@@fsm_guard] ppx expansion references [Keeper_fsm_guard_runtime]. *)

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
