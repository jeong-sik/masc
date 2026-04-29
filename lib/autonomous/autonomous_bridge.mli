(** Autonomous_bridge — non-invasive observer that wraps
    {!Autonomous_state} for use by the Keeper post-turn lifecycle.

    Cycle 22 / Tier A4 — first cut.

    {1 Scope of this PR}

    - {!running_valid} phantom witness: a single-constructor type
      whose value can only be produced inside a Keeper code path
      that has already proven the FSM is in [Running] phase. This
      Tier exposes the type; Tier A5 wires the actual Keeper-side
      production point.
    - {!t} opaque record carrying the current {!Autonomous_state.t}
      and tick bookkeeping.
    - {!create} constructor requiring a {!running_valid} witness
      so external code cannot fabricate a bridge outside a Running
      Keeper.
    - {!tick} delegates to {!Autonomous_state.tick}, returning a
      {!Shared_types.Resilience_outcome.t} so [PartialSuccess] is
      first-class (Decision 6).
    - {!suspend} / {!resume} provide a JSON round-trip surface for
      working_context["autonomous_meta"] persistence (the eventual
      A5 wire-in target).

    {1 Why a phantom witness?}

    OCaml's type system cannot natively express "you can only call
    [create] when the runtime [Keeper.phase = Running]". The
    standard substitution is a witness type whose values can only
    be produced by a function that {e itself} performs the runtime
    check. Here:

    - {!running_valid} has only one constructor: [Running_witness].
    - The constructor is exposed by {!Witness} so that A5's
      Keeper code can produce it after checking
      [Keeper_state_machine.can_execute_turn].
    - {!create} accepts only a [running_valid] argument, so any
      caller must have come through that path.

    The discipline relies on convention — OCaml does not prevent
    [Running_witness] from being mentioned outside the Keeper code
    path. The witness pattern is a {b cooperation contract}, not a
    hard invariant. The same protection used in OAS for similar
    layered checks. Tier A5 layers this contract by hosting the
    only call site in [Keeper_post_turn].

    {1 Deferred to later Tiers}

    - Hooks integration ([Hooks.hook_decision] return type for
      [tick]) — Tier A5+.
    - Memory / Checkpoint / Orchestrator wire-in — later Cycles
      ([Resource_budget], [Goal_dag] dependencies first).
    - {!resume} JSON validation: currently accepts the schema
      emitted by {!suspend} only, errors on anything else. *)

(** {1 Phantom witness} *)

(** Cooperation contract that the caller has verified the Keeper
    is in [Running] phase. Single constructor; values are only
    fabricated by trusted code paths. *)
type running_valid

(** A4-internal accessor for the witness constructor. Tier A5 will
    re-export it from a Keeper-side module so production callers
    pass through that namespace. *)
module Witness : sig
  val running_witness : running_valid
end

(** {1 The bridge value} *)

(** Opaque record. The internal shape carries the current
    {!Autonomous_state.t}, an iteration count, and timestamps.
    External code should rely only on the accessors below. *)
type t

(** {1 Construction and inspection} *)

val create :
  running_valid -> ?meta:Yojson.Safe.t -> now:float -> unit -> t
(** Build a bridge in the [Idle] phase. The [running_valid]
    witness is consumed (not retained) — its only purpose is the
    type-level cooperation gate. The trailing [()] is the standard
    OCaml convention for "optional argument followed by labelled
    arguments only" — it pins the application point so [?meta]
    defaults to [`Null] when omitted. *)

val current_state : t -> Autonomous_state.t
(** Snapshot of the wrapped autonomous state. *)

val current_phase : t -> Autonomous_phase.tag
(** Convenience for [Autonomous_state.current_phase (current_state b)]. *)

val current_phase_string : t -> string

val iteration_count : t -> int
val created_at : t -> float
val last_tick_at : t -> float

(** {1 Lifecycle} *)

val tick :
  t -> now:float -> (t, string) Shared_types.Resilience_outcome.t
(** Advance the bridge by delegating to {!Autonomous_state.tick}.

    {b Stub}: this Tier does not wire keeper events into the call.
    A5 layers the event input + Hooks hook_decision return.

    The error type is fixed to [string] for now — Tier B6
    introduces [Recovery.strategy], with no constructor renaming. *)

(** {1 Persistence} *)

val suspend : t -> Yojson.Safe.t
(** Serialise the bridge to JSON. Output schema:

    {[
    {
      "kind": "autonomous_bridge.v0",
      "iteration_count": <int>,
      "created_at": <float>,
      "last_tick_at": <float>,
      "state": <Autonomous_state.to_json output>
    }
    ]}

    Used by A5 to write [working_context["autonomous_meta"]]. *)

val resume :
  running_valid ->
  Yojson.Safe.t ->
  now:float ->
  (t, string) result
(** Reconstruct a bridge from {!suspend} output. The [now]
    argument lets the caller pin [last_tick_at] to a fresh time
    if desired (e.g. on Keeper restart).

    Returns [Error] when the JSON does not match the v0 schema
    or any required field is missing/malformed.

    {b Stub limitation}: the wrapped {!Autonomous_state.t} is
    re-initialised in [Idle] with the prior [meta] payload; the
    full state restore comes when {!Autonomous_state.of_json}
    lands in a later Tier. The [iteration_count] and timestamps
    are restored faithfully. *)
