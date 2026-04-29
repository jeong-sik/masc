(** Crew_types — common types for the CREW deliberation framework.

    Cycle 25 / Tier A8.

    {1 What this module is}

    Shared types used across the CREW family of modules
    (persona_contract, council, deliberation, consensus, audit).
    Lives separately from {!Persona_contract} so that downstream
    modules in subsequent tiers can depend on these enums and
    identifier types without pulling in the contract record
    payloads.

    {1 Persona kind}

    {!persona_kind} is the four-way tag that bridges
    {!Persona_contract.contract} GADT (compile-time
    discrimination) and runtime indexing (e.g. when reading a
    persona name from a JSON config or persisting a vote
    keyed by persona). The structural mirror has [\[@tla.symbol\]]
    overrides so {!persona_kind_to_string} round-trips through
    the canonical lowercase form ([analyst] / [executor] /
    [scholar] / [verifier]) used in [config/personas/*/profile.json].

    {1 Vote}

    {!vote} encodes the trinary outcome of a single persona's
    judgement during a deliberation phase: {!Approve},
    {!Dissent} (with reason string), or {!Abstain}. Tier A9's
    council_state machine consumes this enum directly.

    {1 Council identifier}

    {!council_id} is an opaque string-newtype carrying a unique
    council instance identifier (typically ULID-shaped,
    constructed by the caller). This module does not generate
    identifiers — it only validates length on {!of_string}.
    Tier A9 wires real ULID generation alongside the council
    state machine.

    @stability Evolving
    @since 0.18.10 *)

(** {1 Persona kind} *)

type persona_kind =
  | Analyst
  | Executor
  | Scholar
  | Verifier

val all_persona_kinds : persona_kind list

val persona_kind_to_string : persona_kind -> string
(** Lowercase canonical name. {!Analyst} → ["analyst"], etc. *)

val persona_kind_of_string_opt : string -> persona_kind option
(** Inverse of {!persona_kind_to_string}. Case-insensitive on
    input. Returns [None] for unknown strings. *)

val persona_kind_to_json : persona_kind -> Yojson.Safe.t

val persona_kind_of_json : Yojson.Safe.t -> (persona_kind, string) result

(** {1 Vote} *)

type vote =
  | Approve
  | Dissent of string
      (** Reason for dissent. The follow-up Tier A10 (consensus)
          inspects this string when computing whether dissent
          carries an override flag. *)
  | Abstain

val vote_to_json : vote -> Yojson.Safe.t

val vote_of_json : Yojson.Safe.t -> (vote, string) result

val vote_label : vote -> string
(** ["approve"] / ["dissent"] / ["abstain"]. Reason text is
    not included — this is the discriminator only. *)

(** {1 Council identifier} *)

type council_id = private string

val council_id_of_string : string -> (council_id, string) result
(** Validates the string is non-empty and ≤ 64 chars. *)

val council_id_to_string : council_id -> string

val council_id_to_json : council_id -> Yojson.Safe.t

val council_id_of_json : Yojson.Safe.t -> (council_id, string) result

val council_id_compare : council_id -> council_id -> int

val council_id_equal : council_id -> council_id -> bool
