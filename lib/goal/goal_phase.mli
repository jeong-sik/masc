(** Read-only Goal lifecycle view.

    The stored phase is abstract. [Completed] below is an observation constructor,
    not a value of [t], so callers cannot manufacture a terminal Goal phase. *)

type t = Goal_store.Phase.t

type view = Goal_store.Phase.view =
  | Executing
  | Blocked
  | Paused
  | Completed
  | Dropped

type nonterminal = Goal_store.Phase.nonterminal =
  | N_executing
  | N_blocked
  | N_paused
  | N_dropped

val view : t -> view
val to_string : t -> string
val view_to_string : view -> string
val of_string : string -> view option
val parse : string -> view option
val to_yojson : t -> Yojson.Safe.t
val view_to_yojson : view -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (view, string) result
val all : view list
val nonterminal_to_view : nonterminal -> view

val executing : t
val blocked : t
val paused : t
val dropped : t

val is_executing : t -> bool
val is_blocked : t -> bool
val is_paused : t -> bool
val is_completed : t -> bool
val is_dropped : t -> bool
val admits_self_directed_progress : t -> bool

type action = Goal_store.Phase.action =
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

type transition_outcome = Goal_store.Phase.transition_outcome =
  | Move_to of nonterminal
  | Complete

val decide_transition :
  phase:t -> action:action -> (transition_outcome, string) result
