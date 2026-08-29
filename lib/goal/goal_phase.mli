(** Goal_phase — state machine SSOT for goal lifecycle.

    Encodes the six phases a goal can be in, the operator/system
    actions that drive transitions, and the deterministic decision
    function {!decide_transition}. Used by the goal subsystem to keep
    transition logic out of caller code.

    RFC-0387 stage 2: [Verifying] sits between [Executing] and
    [Completed] — [Request_complete] enters it, and only the verifier's
    [Record_proof_proven] leaves it for [Completed]. *)

(** Goal lifecycle phases. *)
type t =
  | Executing
  | Verifying
      (** Completion requested; the proof verdict is pending out-of-band
          (RFC-0387 B3). *)
  | Completed
  | Dropped

val to_string : t -> string
(** Lowercase canonical name ([Executing -> "executing"], …). *)

val of_string : string -> t option
(** Inverse of {!to_string}. Returns [None] for unknown input. *)

val parse : string -> t option
(** Like {!of_string} but trims whitespace and lowercases first. *)

val to_yojson : t -> Yojson.Safe.t

val of_yojson : Yojson.Safe.t -> (t, string) result

val all : t list
(** Every phase in declaration order. SSOT for callers that need the full
    string set (MCP schema enum, validator) via [List.map to_string all]. *)

val admits_self_directed_progress : t -> bool
(** Whether a keeper waking on this goal can make progress on it. [Verifying]
    admits continued progress on the linked tasks while the completion proof
    is judged out-of-band: the gate holds the phase, not the work. *)

(** Operator / system actions that may drive a transition. *)
type action =
  | Request_complete
  | Drop
  | Reopen
  | Record_proof_proven
      (** Verifier commit: the completion proof held. [Verifying ->
          Completed]. Requires non-blank evidence at the tool boundary. *)
  | Record_proof_refuted
      (** Verifier commit: the completion proof failed. [Verifying ->
          Executing]; the refutation reason stays in the ledger and
          goal_events. *)

val action_to_string : action -> string
val action_of_string : string -> action option
val all_actions : action list
(** Every internal action in declaration order. Includes verifier-only ledger
    commits and is the SSOT for the exhaustive transition matrix. *)

module Public_action : sig
  (** Lifecycle requests exposed by [masc_goal_transition]. Verifier verdicts
      are deliberately absent: they enter through the application-owned typed
      authority boundary, never through an MCP caller. *)
  type t =
    | Request_complete
    | Drop
    | Reopen

  val to_action : t -> action
  val to_string : t -> string
  val of_string : string -> t option
  val parse : string -> t option
  val all : t list
end

(** What a transition request resolves to.

    [Move_to] is a phase change: the caller writes the new phase and records
    the event. [Already] is the same request made against a goal that is
    already in the phase the action targets — satisfied, with nothing to write.
    A caller that treats the two alike turns a repeated report into repeated
    history. *)
type outcome =
  | Move_to of t
  | Already of t

val decide_transition :
  phase:t ->
  action:action ->
  (outcome, string) result
(** Pure transition decider: what the request resolves to, or [Error msg] for a
    pair that names no reachable phase.

    The diagonal — an action whose target phase the goal already occupies —
    answers [Already] rather than an error, which is what the Task FSM already
    says for the same shape (Cancel on Cancelled, Done_action on Done). Not
    every terminal pair is on it: [Dropped, Request_complete] is still an
    error, because completion is not the phase a dropped goal is in. *)
