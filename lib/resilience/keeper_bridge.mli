(** Resilience keeper_bridge — post-turn resilience pipeline.

    Cycle 23 / Tier A6.

    {1 What this module is}

    A6 wires the {!Recovery} classifier and the canonical
    {!Recovery.default_strategy} mapping into the keeper post-turn
    lifecycle. It runs {b immediately after} the A5 autonomous
    wire-in: the keeper-side dispatch enforces the strict ordering
    [autonomous tick → resilience classification → audit log entry].

    {1 Two surfaces}

    - {b Pure helpers} ({!masc_resilience_enabled},
      {!upsert_resilience_meta}): mirror the A5
      [Autonomous.Wirein_helpers] pattern so [Keeper_post_turn]
      dispatches through this module without pulling the full
      Resilience implementation into the keeper sub-library closure.
    - {b Main pipeline} ({!apply_post_turn_resilience}): given an
      optional error string surfaced by the just-completed turn,
      classify it via {!Recovery.classify_string}, derive the
      canonical strategy class via {!Recovery.default_strategy},
      append an audit envelope (when an audit store is supplied),
      and return a [`Assoc] meta sub-tree to be merged into
      [working_context["resilience_meta"]].

    {1 Feature flag contract}

    [MASC_RESILIENCE] is independent from A5's [MASC_AUTONOMOUS].
    A5 wire-in may be active without A6, and vice versa. The
    keeper-side dispatch enforces the [autonomous → resilience]
    ordering only when both are enabled; either flag being off
    short-circuits its pipeline to a no-op pass-through.

    {1 Phantom witness}

    {!running_valid_for_resilience} is a cooperation token the
    keeper produces only after consulting
    [Keeper_state_machine.can_execute_turn]. The bridge cannot
    be invoked without it, so non-Running keepers are excluded
    at the type level rather than via runtime guard.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Pure helpers} *)

val masc_resilience_enabled : unit -> bool
(** [true] iff the [MASC_RESILIENCE] environment variable is set
    to one of ["1"], ["true"], ["yes"], or ["on"] (lowercase only).
    The default ([false]) keeps the resilience wire-in inert —
    calling [Keeper_post_turn.apply_post_turn_lifecycle] is
    identical to its pre-A6 behaviour. *)

val upsert_resilience_meta :
  Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
(** [upsert_resilience_meta wc meta] returns a JSON [`Assoc]-shaped
    working_context with the ["resilience_meta"] key set to [meta].

    - [wc = None] → fresh [`Assoc] with one entry.
    - [wc = Some (`Assoc kv)] → preserves all keys other than
      ["resilience_meta"] and replaces (or adds) that single entry.
      Critically, this preserves an A5-emitted ["autonomous_meta"]
      entry — the two wire-ins coexist in the same working_context.
    - [wc = Some other] (non-[`Assoc] payload) → wraps under a fresh
      [`Assoc] holding only ["resilience_meta"]. The caller is
      expected to use [`Assoc] working_contexts; this branch exists
      for graceful fallback. *)

(** {1 Phantom witness} *)

(** Cooperation token: only callers that already verified the keeper
    is in a [Running] phase may produce one. *)
type running_valid_for_resilience = Resilience_witness

val running_witness : running_valid_for_resilience
(** The sole inhabitant of {!running_valid_for_resilience}. Produced
    keeper-side after consulting [Keeper_state_machine.can_execute_turn]. *)

(** {1 Main pipeline} *)

(** Outcome of {!apply_post_turn_resilience}. *)
type apply_outcome = {
  working_context : Yojson.Safe.t option;
      (** Updated [`Assoc] working_context with the new
          ["resilience_meta"] entry (when [maybe_error] was
          [Some _]), or the input pass-through (when [None]). *)
  resilience_meta : Yojson.Safe.t option;
      (** The meta sub-tree just written, for diagnostic/inspection
          use. [None] when no error was classified. *)
  audit_envelope_id : string option;
      (** Identifier of the audit envelope appended for this turn,
          if any. [None] when no error was classified or when the
          [audit_store] argument was [None]. *)
}

val apply_post_turn_resilience :
  running_valid_for_resilience ->
  ?audit_store:Shared_audit.Store.t ->
  now:float ->
  working_context:Yojson.Safe.t option ->
  maybe_error:string option ->
  unit ->
  apply_outcome
(** Run the resilience pipeline for one turn.

    @param running_valid_for_resilience phantom witness that the
           keeper FSM is in a [Running] phase.
    @param audit_store optional handle. When omitted, no audit
           envelope is written; the [audit_envelope_id] field is
           [None].
    @param now wall-clock seconds since epoch. Recorded in both
           the audit payload and the meta sub-tree.
    @param working_context current [`Assoc kv] tree, or [None].
    @param maybe_error optional error string surfaced by the
           just-completed turn. [None] short-circuits to a no-op
           pass-through (returned [apply_outcome] has all-[None]
           meta fields and [working_context] equal to the input).

    Side effects:
    - Audit envelope appended to [audit_store] (when supplied and
      [maybe_error] is [Some _]).

    No other state is mutated. Pure with respect to OCaml memory. *)
