(** Autonomous_state — pure state value for the autonomous loop.

    Cycle 21 / Tier B4 — first cut.

    {1 Scope of this PR}

    - {!ctx} GADT type with 8 constructors, one per phase. Only
      {!Idle_ctx} is fully defined (carries [created_at] and a
      placeholder [meta] JSON payload). The other 7 are stub
      variants with no payload, to be filled in by later Tiers when
      the upstream modules land (Stimulus, Intent, Plan,
      Orchestrator, etc.). The phase-indexed types still mirror
      {!Autonomous_phase}'s 8 phantom witnesses.
    - {!t} record carrying an existential phase witness, an
      existential ctx, and bookkeeping ([iteration_count],
      [created_at], [last_tick_at]).
    - {!init} returning an Idle state.
    - {!tick} that always returns
      [Resilience_outcome.FullSuccess]; concrete sub-phase
      transition logic is deferred to Tier A4
      ([Autonomous_bridge.tick]).
    - {!to_json} for deterministic test assertions.

    {1 Why existential packing inside the record?}

    OCaml records cannot have universally polymorphic fields like
    [phase_any : 'a. 'a Autonomous_phase.any]; the only way to
    carry a value whose phantom type is hidden behind an
    existential is to wrap it in another GADT constructor that
    erases the type parameter ({!phase_packed} and {!ctx_packed}).
    Pattern matching on those wrappers re-introduces the unknown
    [type a.] locally where needed, which is how the mli/ml
    boundary stays honest about the heterogeneity.

    {1 Deferred (later Tiers)}

    - Full {!Idle_ctx} fields: [Resource_budget.snapshot],
      [Goal_dag.t], [Self_priority.t]. Requires those modules,
      which arrive in later Cycles.
    - Other ctx constructors' payloads (Stimulus list, Intent.t
      option, Plan.t, etc.).
    - [apply_transition] — Tier B5 introduces the transition GADT.
    - [of_json] — paired with the schema settling (Idle_ctx
      gaining real fields).
    - Memory/Checkpoint integration — Tier A5. *)

(** {1 Phase-indexed context}

    Each constructor narrows the phase index ['phase] to a specific
    {!Autonomous_phase} witness. Only [Idle_ctx] is fully
    populated at this Tier; the other seven are stub markers
    reserved for the type system. *)
type 'phase ctx =
  | Idle_ctx : {
      created_at : float;
      meta : Yojson.Safe.t;
        (** Placeholder for budget / goals / priority payload until
            those modules land. *)
    }
      -> Autonomous_phase.idle ctx
  | Perceiving_ctx : Autonomous_phase.perceiving ctx
  | Intending_ctx : Autonomous_phase.intending ctx
  | Planning_ctx : Autonomous_phase.planning ctx
  | Executing_ctx : Autonomous_phase.executing ctx
  | Verifying_ctx : Autonomous_phase.verifying ctx
  | Reflecting_ctx : Autonomous_phase.reflecting ctx
  | Adapting_ctx : Autonomous_phase.adapting ctx

(** {1 Existential packings for record-level erasure} *)

(** Packs an [_ Autonomous_phase.any] witness, hiding the phantom
    index. Used inside {!t} where universal-polymorphic fields are
    not expressible. *)
type phase_packed =
  | Packed_phase : 'a Autonomous_phase.any -> phase_packed

(** Packs a {!ctx} value, hiding the phantom index. *)
type ctx_packed = Packed_ctx : 'a ctx -> ctx_packed

(** {1 The state record} *)

type t = {
  phase : phase_packed;
  ctx : ctx_packed;
  iteration_count : int;
  created_at : float;
  last_tick_at : float;
}

(** {1 Construction and inspection} *)

val init : ?meta:Yojson.Safe.t -> now:float -> unit -> t
(** Create an initial state in the [Idle] phase. [meta] defaults
    to [`Null] and is reserved for future budget/goals/priority
    payloads. *)

val current_phase : t -> Autonomous_phase.tag
(** The phase tag of the current state. *)

val current_phase_string : t -> string
(** [Autonomous_phase.to_tla_symbol (current_phase t)]. *)

val iteration_count : t -> int
val created_at : t -> float
val last_tick_at : t -> float

(** {1 Lifecycle} *)

val tick :
  t -> now:float -> (t, string) Shared_types.Resilience_outcome.t
(** Advance the loop by one iteration.

    {b Stub}: the current implementation increments
    [iteration_count], updates [last_tick_at] to [now], and returns
    [FullSuccess] with full confidence and no artifacts. Real
    sub-phase progression (Idle → Perceiving → ...) is deferred to
    Tier A4 ([Autonomous_bridge.tick]) which wires this into the
    Keeper observer pipeline.

    The error type is fixed to [string] for now — Tier B6
    introduces [Recovery.strategy] which will be re-targeted by a
    follow-up PR with no constructor renaming. *)

(** {1 Serialisation} *)

val to_json : t -> Yojson.Safe.t
(** Render the state to JSON. The current phase is serialised via
    {!Autonomous_phase.to_tla_symbol}. The [Idle_ctx] [meta]
    payload, when present, is included verbatim under
    ["ctx_meta"]. *)
