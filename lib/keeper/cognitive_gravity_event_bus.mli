(** Cognitive Gravity Event Bus — Phase4 GC Trigger Wiring Interface.

    Implements the trigger registry / dispatch layer described in
    rondo's task-1282 consolidated design and garnet's original
    Phase4 trigger taxonomy (8 trigger types, merging both sources).

    @see <p-fafed821f4c8d5b6d87106c4bc82fbc0> rondo design
    @see garnet Phase4 original trigger taxonomy *)

type decay_trigger =
  | TurnElapsed
  | NoNewMentions
  | Contradiction
  | ManualDecay
  | KeeperVerification  (* sangsu's 3rd missing type *)
  | TaskCycle
  | KnowledgeImport
  | DecayResistance

val trigger_weight : decay_trigger -> float
(** Weight used to accumulate decay score per trigger.
    Sum of concurrent triggers >= 0.7 triggers GC sweep. *)

type event = {
  trigger : decay_trigger;
  ts_unix : float;
  keeper_id : string;
}

type handler = event -> unit

val register_trigger : keeper_id:string -> handler -> unit
(** Register a handler to fire immediately on emit. *)

val emit : event -> unit
(** Emit an event: append to pending queue + fire registered handlers. *)

val dispatch : keeper_id:string -> int
(** Drain pending events for [keeper_id].
    Returns 1 if accumulated decay >= 0.7 (GC signalled), else 0. *)

val peek : keeper_id:string -> event list
(** Peek pending events for [keeper_id] without draining. *)

val make_event : trigger:decay_trigger -> keeper_id:string -> unit -> event
(** Build an event with current Unix timestamp. *)

val emit_trigger : trigger:decay_trigger -> keeper_id:string -> unit
(** make_event + emit in one call. *)