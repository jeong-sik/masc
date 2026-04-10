(** Orthogonal state machine composition — Keeper x Agent_turn x Tool_validation.

    Three independent FSMs composed into a product state with cross-dimension
    invariant checking. Each dimension evolves independently; synchronization
    happens only at explicit guard points.

    Follows the UML orthogonal regions pattern. The keeper FSM is reused
    from {!Keeper_state_machine} without modification (TLA+ verified).

    Phase 1 (advisory): invariant violations are logged, not enforced.
    Phase 2 (enforcing): violations reject the transition.

    @stability Evolving
    @since 2.260.0 *)

(** {1 Dimension 1: Keeper Lifecycle (re-export)} *)

module Keeper = Keeper_state_machine

(** {2 Dimension 2: Agent Turn Lifecycle} *)

module Agent_turn : sig
  type phase =
    | Idle            (** Waiting for next turn *)
    | Prompting       (** Constructing API request *)
    | Awaiting        (** Waiting for LLM response *)
    | Parsing         (** Parsing LLM response *)
    | Dispatching     (** Executing tool calls *)
    | Collecting      (** Collecting tool results *)
    | Finalizing      (** Post-turn hooks *)

  val phase_to_string : phase -> string
  val all_phases : phase list

  type event =
    | Turn_start
    | Prompt_ready
    | Response_received
    | Parse_complete
    | Tools_dispatched
    | Results_collected
    | Turn_complete
    | Turn_error of string

  val event_to_string : event -> string

  (** Pure transition function. *)
  val apply_event : current:phase -> event -> phase
end

(** {3 Dimension 3: Tool Validation Lifecycle} *)

module Tool_validation : sig
  type phase =
    | Unchecked       (** Raw JSON received *)
    | Det_correcting  (** Running deterministic correction stages *)
    | Det_valid       (** Passed after deterministic correction *)
    | Det_invalid     (** Failed deterministic, awaiting NonDet *)
    | Nondet_retrying (** LLM re-prompt in progress *)
    | Valid           (** Passed validation (det or nondet) *)
    | Rejected        (** Failed all retries *)

  val phase_to_string : phase -> string
  val all_phases : phase list

  type event =
    | Validate_start
    | Det_fixed
    | Det_failed
    | Nondet_attempt of int
    | Nondet_fixed
    | Nondet_exhausted
    | Skip_validation

  val event_to_string : event -> string

  (** Pure transition function. *)
  val apply_event : current:phase -> event -> phase
end

(** {4 Product State} *)

type product = {
  keeper : Keeper.phase;
  turn : Agent_turn.phase;
  validation : Tool_validation.phase;
}

val initial : product
(** [{ keeper = Offline; turn = Idle; validation = Unchecked }] *)

(** {5 Cross-Dimension Invariants} *)

(** Check cross-dimension invariants on the product state.

    Returns [Ok ()] if consistent, [Error reason] if violated.

    Invariants enforced:
    - Keeper in [Stopped | Dead] -> turn must be [Idle]
    - Keeper in [Draining] -> turn must be [Idle | Finalizing]
    - Validation in [Nondet_retrying] -> turn must be [Dispatching]
    - Keeper in [Compacting] -> turn must not be [Prompting | Awaiting] *)
val check_invariants : product -> (unit, string) result

(** {6 Unified Event Dispatch} *)

type event =
  | K of Keeper.event
  | T of Agent_turn.event
  | V of Tool_validation.event

val event_to_string : event -> string

(** Apply an event to the appropriate dimension, then check invariants.

    Returns the new product state or an invariant violation error.
    For keeper events, delegates to {!Keeper_state_machine.apply_event}
    which requires [conditions] and [now]. *)
val apply_turn_event :
  product -> Agent_turn.event -> (product, string) result

val apply_validation_event :
  product -> Tool_validation.event -> (product, string) result

(** {7 Serialization} *)

val product_to_json : product -> Yojson.Safe.t
