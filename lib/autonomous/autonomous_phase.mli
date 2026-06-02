(** Autonomous_phase — sub-phase taxonomy for the autonomous loop.

    Cycle 21 / Tier B3 — first cut.

    {1 Scope of this PR}

    - 8 phantom witness types ([idle], [perceiving], [intending],
      [planning], [executing], [verifying], [reflecting], [adapting])
      that exist purely as compile-time tags carried by the [_ any]
      GADT and the [Autonomous_state] context indices.
    - {!tag} regular variant for runtime indexing + ppx_tla derive parity.
    - {!any} 1-parameter GADT existential wrapping each phantom type.
    - {!any_to_tag} / {!any_to_string} projections.

    {1 Deferred to Tier B5}

    - The [('from, 'to_) transition] GADT (19 valid-transition witnesses).
    - Runtime [can_transition] check.
    - Hand-written [transition_to_string].

    {1 Why a separate [tag] type?}

    The {!any} GADT is a 1-parameter existential whose constructors
    each specialise the type parameter to a different phantom witness
    (e.g. [Any_idle : idle any]). The current [ppx_tla] deriver
    cannot emit [to_tla_symbol] for this shape — Tier I8 deferred
    1+ parameter non-phantom GADTs, and Tier I9's
    [\[@@tla.phantom_param\]] only applies when no constructor
    specialises the parameter.

    Rather than hand-write a parallel [to_tla_symbol_any] that drifts
    against the phantom type set, we mirror the witnesses as a regular
    variant {!tag}, derive the symbol mapping there, and project from
    the GADT to the tag in [any_to_tag]. The single source of truth
    for phase symbol names is the [\[@tla.symbol\]] override on each
    {!tag} constructor. *)

(** {1 Phantom witness types}

    These types have no inhabitants — they exist purely as type-level
    tags. Their abstract status prevents external code from
    fabricating phase witnesses outside this module. *)

type idle
type perceiving
type intending
type planning
type executing
type verifying
type reflecting
type adapting

(** {1 Phase tag (runtime mirror of the witness type set)}

    Each phantom witness type has a corresponding {!tag} constructor.
    The deriver emits [to_tla_symbol], [all_symbols], and [all_states]
    on this type; the GADT {!any} projects to {!tag} via
    {!any_to_tag}. *)
type tag =
  | Tag_idle [@tla.symbol "idle"]
  | Tag_perceiving [@tla.symbol "perceiving"]
  | Tag_intending [@tla.symbol "intending"]
  | Tag_planning [@tla.symbol "planning"]
  | Tag_executing [@tla.symbol "executing"]
  | Tag_verifying [@tla.symbol "verifying"]
  | Tag_reflecting [@tla.symbol "reflecting"]
  | Tag_adapting [@tla.symbol "adapting"]
[@@deriving tla]

(** {1 Existential phase wrapper}

    [_ any] binds a runtime phase value to a compile-time-checked
    phantom witness. [Autonomous_state.t] (Tier B4) carries values of
    type ['phase any] to ensure that phase-indexed contexts cannot be
    mismatched at runtime. *)
type _ any =
  | Any_idle : idle any
  | Any_perceiving : perceiving any
  | Any_intending : intending any
  | Any_planning : planning any
  | Any_executing : executing any
  | Any_verifying : verifying any
  | Any_reflecting : reflecting any
  | Any_adapting : adapting any

val any_to_tag : 'a any -> tag
(** Project a phase witness to its runtime tag. *)

val any_to_string : 'a any -> string
(** Canonical lowercase phase name. Equivalent to
    [to_tla_symbol (any_to_tag x)] — exposed as a convenience and
    so call sites do not need to know about the {!tag} type. *)

(** {1 Transitions}

    Cycle 21 / Tier B5 — the valid sub-phase transition matrix.

    Encoded as a 2-parameter GADT where each constructor narrows
    ['from] and ['to_] to the specific phantom witnesses for the
    source and destination phases. Invalid transitions are simply
    not in the type — impossible to construct.

    The 19 valid transitions match the matrix in
    {b autonomous_ARCHITECTURE.md §3.2}:

    {v
       idle       → perceiving | adapting
       perceiving → idle | intending
       intending  → planning | idle
       planning   → executing | intending
       executing  → verifying | adapting | idle
       verifying  → reflecting | adapting
       reflecting → idle | adapting | planning
       adapting   → planning | idle | perceiving
    v}

    The {!Transition} sub-module isolates the transition-tag
    deriver output ([to_tla_symbol], [all_symbols], [all_states])
    from the phase-tag deriver output of the same name in the
    enclosing module — both are emitted by [@@deriving tla] but
    operate on different types. *)
module Transition : sig
  (** {1 Transition GADT} *)

  type ('from, 'to_) t =
    | Idle_to_perceiving : (idle, perceiving) t
    | Idle_to_adapting : (idle, adapting) t
    | Perceiving_to_idle : (perceiving, idle) t
    | Perceiving_to_intending : (perceiving, intending) t
    | Intending_to_planning : (intending, planning) t
    | Intending_to_idle : (intending, idle) t
    | Planning_to_executing : (planning, executing) t
    | Planning_to_intending : (planning, intending) t
    | Executing_to_verifying : (executing, verifying) t
    | Executing_to_adapting : (executing, adapting) t
    | Executing_to_idle : (executing, idle) t
    | Verifying_to_reflecting : (verifying, reflecting) t
    | Verifying_to_adapting : (verifying, adapting) t
    | Reflecting_to_idle : (reflecting, idle) t
    | Reflecting_to_adapting : (reflecting, adapting) t
    | Reflecting_to_planning : (reflecting, planning) t
    | Adapting_to_planning : (adapting, planning) t
    | Adapting_to_idle : (adapting, idle) t
    | Adapting_to_perceiving : (adapting, perceiving) t

  (** {1 Tag mirror}

      Same shape as the GADT but as a regular variant, so the
      ppx_tla deriver can emit symbol mappings. The
      [\[@tla.symbol\]] override formats each tag as ["from->to"]
      (e.g. ["idle->perceiving"]). *)
  type tag =
    | T_idle_to_perceiving [@tla.symbol "idle->perceiving"]
    | T_idle_to_adapting [@tla.symbol "idle->adapting"]
    | T_perceiving_to_idle [@tla.symbol "perceiving->idle"]
    | T_perceiving_to_intending [@tla.symbol "perceiving->intending"]
    | T_intending_to_planning [@tla.symbol "intending->planning"]
    | T_intending_to_idle [@tla.symbol "intending->idle"]
    | T_planning_to_executing [@tla.symbol "planning->executing"]
    | T_planning_to_intending [@tla.symbol "planning->intending"]
    | T_executing_to_verifying [@tla.symbol "executing->verifying"]
    | T_executing_to_adapting [@tla.symbol "executing->adapting"]
    | T_executing_to_idle [@tla.symbol "executing->idle"]
    | T_verifying_to_reflecting [@tla.symbol "verifying->reflecting"]
    | T_verifying_to_adapting [@tla.symbol "verifying->adapting"]
    | T_reflecting_to_idle [@tla.symbol "reflecting->idle"]
    | T_reflecting_to_adapting [@tla.symbol "reflecting->adapting"]
    | T_reflecting_to_planning [@tla.symbol "reflecting->planning"]
    | T_adapting_to_planning [@tla.symbol "adapting->planning"]
    | T_adapting_to_idle [@tla.symbol "adapting->idle"]
    | T_adapting_to_perceiving [@tla.symbol "adapting->perceiving"]
  [@@deriving tla]

  (** {1 Projections} *)

  val to_tag : ('from, 'to_) t -> tag
  (** Project a transition witness to its runtime tag. Hand-
      written: a 1+ parameter non-phantom GADT cannot be derived
      (Tier I8 deferral; Tier I9's [\[@@tla.phantom_param\]] does
      not apply because each constructor specialises the
      parameters). *)

  val to_string : ('from, 'to_) t -> string
  (** Canonical "from->to" label. Equivalent to
      [to_tla_symbol (to_tag t)]. *)

  (** {1 Runtime validation} *)

  val can_transition : from_:'a any -> to_:'b any -> bool
  (** Conservative runtime check: returns [true] iff some
      constructor of {!t} witnesses the pair
      [(any_to_tag from_, any_to_tag to_)]. The type system
      already prevents invalid constructions at compile time;
      this function exists for serialised data validation and
      operator-override safety. *)
end
