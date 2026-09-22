(** The keeper turn as the caller scope of the agent-core bus a turn's agent
    publishes on.

    A keeper turn is several provider calls, and an agent session created
    without a checkpoint numbers those calls from zero again, so the agent's
    own ordinal cannot say which keeper turn an event belongs to. The turn
    hands its agent a bus handle scoped to its keeper turn id; every event the
    agent publishes carries it, and the event bridge reads it back here. This
    module is the only place that knows how the id is spelled inside the
    scope. *)

(** [bus event_bus ~keeper_turn_id] is [event_bus] for publishing on behalf of
    keeper turn [keeper_turn_id]. *)
val bus : Agent_core.Event_bus.t -> keeper_turn_id:int -> Agent_core.Event_bus.t

(** The keeper turn id a scope made by {!bus} names. [Error] for a scope this
    module did not make. *)
val keeper_turn_id : Agent_core.Caller_scope.t -> (int, string) result
