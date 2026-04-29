(** Degradation — tiered capability levels for resilience.

    Cycle 27 / Tier A11 (partial — degradation only; speculative
    in companion module {!Speculative}).

    {1 What this module is}

    A 4-level capability lattice the resilience layer steps through
    when {!Recovery.default_strategy} is insufficient (escalate)
    or excessive (de-escalate). The {!level} GADT is phantom-tagged
    so legitimate transitions are encoded at the type level.

    {1 The level lattice}

    - {!L1}: full capability — all tools, all branches, no caps
      applied beyond the keeper's normal budget.
    - {!L2}: reduced — drops creative/external tools (image
      generation, network fetch); core reasoning + read tools
      remain.
    - {!L3}: skeleton — drops all tool use; the agent emits
      plan-only / schema-only artifacts.
    - {!L4}: fallback — drops the agent entirely; static
      pre-canned response.

    Each level carries an empty phantom witness type so the GADT's
    type parameter narrows specifically per-constructor; the
    structural mirror {!level_tag} provides a derivable variant
    for ppx_tla and runtime indexing.

    {1 Numeric mapping}

    The companion stub field [Resilience_outcome.PartialSuccess.degradation_level]
    carries an [int] in [\[1, 4\]]. {!to_int} and {!of_int_opt} are
    the canonical bridges; the integer encoding is the lattice
    ordinal (lower = higher capability).

    {1 Policy lineage (placeholder)}

    {!authorize_transition} returns [Ok ()] unconditionally in
    this PR; the real OAS [Policy.evaluate_with_lineage] integration
    lands in a follow-up tier (A11b) without renaming the function.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Phantom witnesses}

    Empty-variant declarations (no inhabitants). Internal use is
    purely type-level — no value of these types is ever
    constructed. *)

type full_capability
type reduced_capability
type skeleton_capability
type fallback_capability

(** {1 Level GADT} *)

type _ level =
  | L1 : full_capability level
  | L2 : reduced_capability level
  | L3 : skeleton_capability level
  | L4 : fallback_capability level

(** Existential capture for storing levels of mixed capability
    in homogeneous lists or APIs that defer dispatch to runtime. *)
type any_level = Any_level : 'a level -> any_level

(** {1 Tag mirror} *)

type level_tag = Tag_l1 | Tag_l2 | Tag_l3 | Tag_l4

val all_level_tags : level_tag list

val level_tag_to_string : level_tag -> string

val level_to_tag : 'a level -> level_tag

val any_level_to_tag : any_level -> level_tag

val level_to_string : 'a level -> string

(** {1 Numeric mapping} *)

val to_int : 'a level -> int

val any_to_int : any_level -> int

val of_int_opt : int -> any_level option
(** [Some] for [1..4], [None] otherwise. *)

(** {1 Authorization (stub)} *)

val authorize_transition :
  from:any_level -> to_:any_level -> (unit, string) result
(** Stub: returns [Ok ()] for any pair. Tier A11b wires real
    OAS Policy lineage. *)

(** {1 Strategy adjustment} *)

val apply_level_to_strategy :
  'a level ->
  Recovery.error_mode ->
  [ `Retry | `Fallback | `Handoff | `Abort ] Recovery.strategy
(** Given a failure mode and a target level, return a policy-
    adjusted recovery strategy:
    - [L1] returns the canonical {!Recovery.default_strategy}.
    - [L2] downgrades [Retry] to [Fallback]; preserves others.
    - [L3] forces a [Handoff] regardless of mode.
    - [L4] forces an [Abort].
    Higher levels are progressively more conservative — once
    skeleton or fallback is required, retrying or substituting
    is no longer appropriate. *)

(** {1 Recovery → Degradation bridge}

    The B6 [Recovery.error_mode.DegradationRequired] constructor
    carries [recommended_level : int] (per the I5 stub note
    pending Tier A11). A direct retype to [Degradation.level]
    on the B6 side would create a circular dependency:
    [Recovery → Degradation → Recovery]. Instead the conversion
    lives here, where [Degradation] already imports
    [Recovery.error_mode].

    {!of_recovery_recommended_level} interprets the integer as
    the lattice ordinal ([1..4]); other modes return [None].
    {!strategy_for_error_mode} composes that lookup with
    {!apply_level_to_strategy} so callers obtain the level-
    adjusted strategy in one call. *)

val of_recovery_recommended_level :
  Recovery.error_mode -> any_level option
(** [of_recovery_recommended_level mode] returns the
    {!any_level} encoded by [mode]'s [recommended_level] field
    when [mode] is [Recovery.DegradationRequired { recommended_level; _ }]
    and [recommended_level] is in [\[1, 4\]]. Returns [None] for
    any other failure mode and for out-of-range integers. *)

val strategy_for_error_mode :
  Recovery.error_mode ->
  [ `Retry | `Fallback | `Handoff | `Abort ] Recovery.strategy
(** [strategy_for_error_mode mode] returns:
    - {!apply_level_to_strategy} of the encoded level when [mode]
      is [DegradationRequired] with a level in [\[1, 4\]].
    - {!Recovery.default_strategy} of [mode] otherwise (other
      failure kinds, and [DegradationRequired] with an
      out-of-range integer).

    This is the canonical entrypoint for callers that have an
    [error_mode] in hand and want a strategy without first
    extracting the level. *)
