(** Resilience keeper_bridge — post-turn resilience pipeline.

    Cycle 23 / Tier A6.

    {1 What this module is}

    A6 wires the {!Recovery} classifier and the canonical
    {!Recovery.default_strategy} mapping into the keeper post-turn
    lifecycle before tool-emission and multimodal hydration.

    {1 Two surfaces}

    - {b Pure helpers} ({!masc_resilience_enabled},
      {!upsert_resilience_meta}) keep [Keeper_post_turn] independent
      from the full Resilience implementation.
    - {b Main pipeline} ({!apply_post_turn_resilience}): given an
      optional error string surfaced by the just-completed turn,
      classify it via {!Recovery.classify_string}, derive the
      canonical strategy class via {!Recovery.default_strategy},
      optionally execute it through caller-supplied concrete
      callbacks, append an audit envelope (when an audit store is
      supplied), and return a [`Assoc] meta sub-tree to be merged
      into [working_context["resilience_meta"]].

    {1 Feature flag contract}

    When [MASC_RESILIENCE] is disabled the pipeline is a no-op
    pass-through.

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
    The default ([false]) keeps the resilience wire-in inert. *)

val upsert_resilience_meta :
  Yojson.Safe.t option -> Yojson.Safe.t -> Yojson.Safe.t option
(** [upsert_resilience_meta wc meta] returns a JSON [`Assoc]-shaped
    working_context with the ["resilience_meta"] key set to [meta].

    - [wc = None] → fresh [`Assoc] with one entry.
    - [wc = Some (`Assoc kv)] → preserves all keys other than
      ["resilience_meta"] and replaces (or adds) that single entry.
      Every unrelated association is preserved.
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
type strategy_execution =
  | Strategy_execution_not_configured
      (** No concrete executor was supplied. No retry, fallback,
          handoff, or abort side effect was attempted. *)
  | Strategy_execution_completed of Recovery.execution_outcome
      (** The selected strategy was consumed by
          {!Recovery.execute_strategy}. The outcome may still be a
          terminal recovery result such as retry exhaustion; this
          constructor means the executor itself ran to completion. *)
  | Strategy_execution_failed of string
      (** The executor failed before producing a recovery outcome. *)

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
  strategy_execution : strategy_execution option;
      (** Strategy execution result for the classified error.
          [None] only when [maybe_error] is [None]. *)
}

val apply_post_turn_resilience :
  running_valid_for_resilience ->
  ?audit_store:Shared_audit.Store.t ->
  ?strategy_executor:Recovery.strategy_executor ->
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
    @param strategy_executor optional concrete strategy executor.
           When omitted, the selected recovery strategy is not run and
           both metadata and [strategy_execution] report
           {!Strategy_execution_not_configured}. When supplied, this
           bridge consumes the default strategy through
           {!Recovery.execute_strategy}; all retry/fallback/handoff/abort
           side effects belong to the executor callbacks.
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
    - Callback side effects performed by [strategy_executor] (when
      supplied and [maybe_error] is [Some _]). *)
