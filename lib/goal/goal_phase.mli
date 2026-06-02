(** Goal_phase — state machine SSOT for goal lifecycle.

    Encodes the seven phases a goal can be in, the operator/system
    actions that drive transitions, and the deterministic decision
    function {!decide_transition}. Used by the goal subsystem to keep
    transition logic out of caller code. *)

(** Goal lifecycle phases. *)
type t =
  | Executing
  | Awaiting_verification
  | Awaiting_approval
  | Blocked
  | Paused
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

(** Operator / system actions that may drive a transition. *)
type action =
  | Request_complete
  | Approve_completion
  | Reject_completion
  | Pause
  | Resume
  | Operator_block
  | Operator_unblock
  | Drop
  | Reopen

val action_to_string : action -> string
val action_of_string : string -> action option
val parse_action : string -> action option

(** Outcome of {!decide_transition}. [Move_to] is a direct phase
    change; [Open_verification] / [Open_approval] gate completion
    behind verifier or operator review; [Complete] is the terminal
    success transition. *)
type transition_outcome =
  | Move_to of t
  | Open_verification
  | Open_approval
  | Complete

val decide_transition :
  phase:t ->
  action:action ->
  has_effective_verifier_policy:bool ->
  require_completion_approval:bool ->
  (transition_outcome, string) result
(** Pure transition decider. Returns [Error msg] for invalid
    [(phase, action)] pairs (the message names both for diagnostics).
    [Awaiting_verification] mirrors [Awaiting_approval] outcomes for
    verifier verdicts (#10411 fix — verification-pinned goals could
    not exit before this). *)
