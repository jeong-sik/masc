(** Goal_phase — state machine SSOT for goal lifecycle.

    Encodes the seven phases a goal can be in, the operator/system
    actions that drive transitions, and the deterministic decision
    function {!decide_transition}. Used by the goal subsystem to keep
    transition logic out of caller code. *)

(** Goal lifecycle phases. *)
type t = private
  | Executing
  | Blocked
  | Paused
  | Completed
  | Dropped

val equal : t -> t -> bool
(** Structural equality. Use this instead of [=] against a constructor: [t] is
    private, so a comparison like [phase = Completed] would have to build a
    [Completed] value and is rejected. *)

val executing : t
val blocked : t
val paused : t
val dropped : t
(** The phases any caller may name. Completion is the only one that needs
    authorization, so it is not here — see {!completed}. *)

val is_executing : t -> bool
val is_blocked : t -> bool
val is_paused : t -> bool
val is_completed : t -> bool
val is_dropped : t -> bool
(** Phase predicates. Counting and filtering go through these: a query must not
    have to mint a [Completed] value just to ask how many goals are in it. *)

type completion_authorization
(** Proof that a semantic completion verdict approved this goal. Abstract, so
    the only way to obtain one is {!authorize_completion}. *)

val authorize_completion : verdict_receipt_id:string -> completion_authorization
(** Mint the authorization from the id of a persisted approving verdict
    receipt. The caller must already hold that receipt; this does not check it,
    it records that a specific one was the basis for completing. *)

val completed : completion_authorization -> t
(** The ONLY way to produce [Completed]. [t] is private, so no caller outside
    this module can write [Completed] directly — a goal cannot reach the
    terminal phase without naming the verdict that authorized it. Prior to this
    the obligation lived in a doc comment on {!decide_transition} saying the
    adapter "must" obtain a verdict, which the compiler did not enforce.

    Deserialization inside this module still reconstructs [Completed] from
    persisted text ({!of_string}, {!of_yojson}). That is replay of an already
    authorized decision, not a new one; the gate is on the transition path. *)

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
(** Pure transition decider. [Request_complete] yields [Complete] from
    [Executing]; the workspace adapter must obtain and atomically persist the
    required semantic completion verdict before committing [Completed].
    Returns [Error msg] for invalid pairs. *)
