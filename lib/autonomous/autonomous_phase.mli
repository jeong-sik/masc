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
