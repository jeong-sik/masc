(** Cognitive Gravity Event Bus — Phase4 GC Trigger Wiring.

    Decay triggers that drive stale-fact reconciliation in Memory OS.
    See {!Cognitive_gravity_event_bus} for implementation. *)

type decay_trigger =
  | TurnElapsed                             (** A keeper turn completed without meaningful change *)
  | NoNewMentions                           (** Board mentions for the keeper are 0 in the current window *)
  | Contradiction                           (** A fact in Memory OS directly contradicts new evidence *)
  | ManualDecay                             (** Explicit decay signal (admin/operator/Phase4e demotion) *)

type event = {
  trigger : decay_trigger;
  ts_unix : float;
  keeper_id : string;
}

(** Register a decay-event handler for a keeper. *)
val register_trigger : string -> (event -> unit) -> unit

(** Emit a decay event to all registered keepers matching the predicate. *)
val emit : event -> unit

(** Dispatch all pending decay events and apply GC on stale facts.
    Returns the number of facts that crossed the stale threshold. *)
val dispatch : string -> int

(** Collect pending events without applying them (for testing/inspection). *)
val peek : string -> event list