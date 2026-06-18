(** Cognitive Gravity Event Bus — Phase4 GC trigger registry + dispatch.

    Design: rondo (task-1282), garnet (task-1280).

    Three-layer architecture:
    1. {!decay_trigger} — typed trigger variants that signal decay conditions.
    2. {!decay_event} — a concrete event emitted when a trigger fires.
    3. {!register_trigger} / {!dispatch} / {!emit} — the registry pattern.

    Events are logged as JSONL rows in the same Dated_jsonl audit store
    used by {!Keeper_compact_audit}.  Actual priority mutation on memory
    rows happens during the next compaction cycle, which reads the event
    log as an input signal.

    Integration point: {!run_gc} called from
    {!Keeper_compact_audit.after_compact} after each compaction completion. *)

(** {1 Types} *)

type decay_trigger =
  | TurnElapsed of { age : int; min_age : int }
  | NoNewMentions of { turns : int; min_idle : int }
  | Contradiction of { fact_id : string; staleness : float }
  | ManualDecay of { fact_ids : string list; rate : float }
(** The four trigger types.
    - {!TurnElapsed}: a fact has aged beyond [min_age] turns.
    - {!NoNewMentions}: no new interactions for [min_idle] turns.
    - {!Contradiction}: a fact has a contradiction gap > 0.
    - {!ManualDecay}: keeper-invoked explicit decay. *)

type decay_event = {
  trigger : decay_trigger;
  target_fact_ids : string list;
  delta : float;            (** score multiplier (0.0 – 1.0) *)
  applied_at_turn : int;    (** system turn when the event was emitted *)
}
(** A concrete decay event ready for application. *)

(** {1 Registry} *)

val register_trigger
  :  decay_trigger
  -> handler:(decay_event -> unit)
  -> unit
(** Register a callback for a specific trigger pattern.
    Multiple handlers may be registered for the same trigger;
    they fire in registration order on dispatch. *)

(** {1 Dispatch} *)

val dispatch : unit -> decay_event list
(** Evaluate all registered triggers against current state and return
    the list of events that fired this cycle.  Idempotent per cycle —
    calling [dispatch] twice within the same turn returns the same
    events. *)

(** {1 Emit} *)

val emit : decay_event -> unit
(** Push a decay event into the processing pipeline without going
    through the trigger registry.  Used by {!ManualDecay} and
    test harnesses. *)

(** {1 Default handler wiring}

    These are the default per-trigger delta values. *)

val default_delta : decay_trigger -> float
(** Delta for each trigger:
    - {!TurnElapsed} → 0.02   (gentle time decay)
    - {!NoNewMentions} → 0.05 (idle-relation decay)
    - {!Contradiction} → 0.10 per gap unit
    - {!ManualDecay} → [rate] field as-is *)

val default_target_fact_ids : decay_trigger -> string list
(** Default fact-target selector for each trigger:
    - {!TurnElapsed} → empty (no default target — caller fills)
    - {!NoNewMentions} → empty (no default target — caller fills)
    - {!Contradiction} → [fact_id] of the contradiction
    - {!ManualDecay} → the explicit [fact_ids] list *)

val default_log_handler : string -> decay_event -> unit
(** [default_log_handler store_base_path event] serialises the event as
    a JSONL row under [data/cognitive-gravity-events/].  Designed to be
    passed as a handler to {!register_trigger} by
    {!Default_triggers.setup}.

    Returns [()] — errors are logged to stderr and swallowed so a
    failing store does not crash the trigger pipeline. *)

(** {1 Default triggers} *)

module Default_triggers : sig
  val setup : store_base_path:string -> unit
  (** Register the canonical trigger set with log handlers:
      - {!TurnElapsed} at [min_age=3]
      - {!NoNewMentions} at [min_idle=5]
      - {!Contradiction} at [staleness=0.3]
      Call once at keeper init. *)
end

(** {1 Run-GC integration} *)

val run_gc : base_path:string -> unit
(** Full GC trigger pass:
    1. Evaluate all registered triggers via {!dispatch}.
    2. Emit each decay event (triggers handlers).
    3. Returns [()] — events are logged to disk by registered handlers.

    Designed to be called from {!Keeper_compact_audit}'s compaction loop
    after score recalculation. *)

module For_testing : sig
  val reset : unit -> unit
end
