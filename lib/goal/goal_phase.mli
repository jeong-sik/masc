(** Goal_phase — state machine SSOT for goal lifecycle.

    Encodes the seven phases a goal can be in, the operator/system
    actions that drive transitions, and the deterministic decision
    function {!decide_transition}. Used by the goal subsystem to keep
    transition logic out of caller code. *)

(** Goal lifecycle phases. *)
type t =
  | Executing
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

val all : t list
(** Every phase in declaration order. SSOT for callers that need the full
    string set (MCP schema enum, validator) via [List.map to_string all]. *)

val admits_self_directed_progress : t -> bool
(** Whether a keeper waking on this goal can make progress on it. *)

(** Operator / system actions that may drive a transition. *)
type action =
  | Request_complete
  | Pause
  | Resume
  | Block
  | Unblock
  | Drop
  | Reopen

val action_to_string : action -> string
val action_of_string : string -> action option
val parse_action : string -> action option

val all_actions : action list
(** Every action in declaration order. SSOT for the schema/validator action
    enum via [List.map action_to_string all_actions]. *)

(** Outcome of {!decide_transition}. [Move_to] is a direct phase change and
    [Complete] is the terminal success transition. *)
type transition_outcome =
  | Move_to of t
  | Complete

val decide_transition :
  phase:t ->
  action:action ->
  (transition_outcome, string) result
(** Pure transition decider. [Request_complete] completes directly from
    [Executing]. Returns [Error msg] for invalid pairs. *)
