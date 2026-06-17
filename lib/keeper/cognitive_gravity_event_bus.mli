(** Cognitive Gravity Event Bus — Phase 4 GC Trigger Wiring

    Provides a registry of decay triggers and a dispatch mechanism
    that integrates with the existing compaction/audit loop.

    Four trigger types:
    - TurnElapsed: facts older than min_age with stale=0.00
    - NoNewMentions: no new interactions for min_idle turns
    - Contradiction: score stable but gap > 0
    - ManualDecay: explicit invocation by keeper
*)

type decay_trigger =
  | TurnElapsed of { age: int; min_age: int }
  | NoNewMentions of { turns: int; min_idle: int }
  | Contradiction of { fact_id: string; staleness: float }
  | ManualDecay of { fact_ids: string list; rate: float }

type decay_event = {
  trigger: decay_trigger;
  target_fact_ids: string list;
  delta: float;
  applied_at_turn: int;
}

val emit : decay_event -> unit
val register_trigger : decay_trigger -> handler:(decay_event -> unit) -> unit
val dispatch : unit -> decay_event list
val apply_decay : decay_event -> unit