(** Persona_contract — phantom-tagged contract record per CREW persona.

    Cycle 25 / Tier A8.

    {1 What this module is}

    A static, type-discriminated contract for each of the four
    base personas (analyst / executor / scholar / verifier). The
    contract records carry the persona's core responsibilities,
    a freeform description, and a forbidden-tools list.
    Compile-time discrimination via the phantom-tagged
    {!contract} record excludes mismatched
    [Analyst-handler over Executor-contract] at the type level.

    {1 Provenance of the contract values}

    A8 hard-codes the four contract values in this module. Tier
    A8b (deferred follow-up) will replace these with a loader
    over [config/personas/<kind>/profile.json] without breaking
    the [analyst_contract] / [executor_contract] / etc. names —
    the values are addressable in the same form whether sourced
    from constants or from disk.

    {1 Phantom witness pattern}

    Each persona has an empty witness type ({!analyst},
    {!executor}, {!scholar}, {!verifier}). The {!contract} record
    carries a phantom parameter that the constructor narrows to
    the correct witness, so a function specialised on
    [analyst contract] cannot be applied to an
    [executor contract]. The {!any_persona} existential lets
    callers pack a heterogeneous list when runtime dispatch is
    appropriate; {!any_persona_kind} extracts the runtime tag.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Phantom witnesses}

    Empty-variant declarations (no inhabitants). External call
    sites see them as abstract; internal use is purely type-level. *)

type analyst
type executor
type scholar
type verifier

(** {1 Contract record} *)

(** Phantom-tagged contract for one persona. The phantom
    parameter ['a] is one of the four witness types above and is
    the compile-time discriminator. The payload is read-only;
    callers do not construct values directly. *)
type 'a contract

(** {1 Static contract values} *)

val analyst_contract : analyst contract
(** The analyst persona contract. Surfaces hidden assumptions,
    decomposes problems into checkable claims, and flags
    rationalization patterns. Forbidden from external API calls. *)

val executor_contract : executor contract
(** The executor persona contract. Carries out concrete actions
    (file edits, shell commands, tool calls) per a plan handed
    down by analyst or scholar. Permitted to use the full
    tool surface. *)

val scholar_contract : scholar contract
(** The scholar persona contract. Researches prior art, retrieves
    documentation, and synthesises options. Permitted to use
    read-only tools (web search, doc fetch); forbidden from
    write side effects. *)

val verifier_contract : verifier contract
(** The verifier persona contract. Reviews artifacts produced
    by other personas, runs evals, asserts correctness. Permitted
    to read and run tests; forbidden from write side effects. *)

(** {1 Existential capture} *)

type any_persona = Any_persona : 'a contract -> any_persona

val all_personas : any_persona list
(** All four personas in canonical declaration order
    [\[Analyst; Executor; Scholar; Verifier\]]. *)

(** {1 Accessors} *)

val name : 'a contract -> string
(** Lowercase canonical name (matches
    [Crew_types.persona_kind_to_string] of {!persona_kind}). *)

val description : 'a contract -> string

val core_responsibilities : 'a contract -> string list

val forbidden_tools : 'a contract -> string list

val persona_kind : 'a contract -> Crew_types.persona_kind

val any_persona_kind : any_persona -> Crew_types.persona_kind

val any_name : any_persona -> string

val any_description : any_persona -> string

(** {1 JSON} *)

val to_json : 'a contract -> Yojson.Safe.t

val any_to_json : any_persona -> Yojson.Safe.t
