(** Producer-owned identity of a top-level Keeper execution. Display counters
    can repeat across attempts; a fresh scope distinguishes those executions. *)
type t

val create : keeper_turn_id:int -> t
val turn_id : t -> int
val bus : Agent_core.Event_bus.t -> scope:t -> Agent_core.Event_bus.t
val filter : t -> Agent_core.Event_bus.filter

(** Decode the display counter from our strict structured scope. Missing,
    foreign or malformed scope values are errors, never guessed counters. *)
val keeper_turn_id : Agent_core.Caller_scope.t -> (int, string) result
