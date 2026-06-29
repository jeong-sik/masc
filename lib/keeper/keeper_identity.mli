(** Keeper_identity — Trace ID generation and keeper-name normalization for
    keeper operations. *)

val generate_trace_id : ?now:float -> unit -> string
(** Generate a unique trace ID from an epoch timestamp and monotonic counter.
    [~now] defaults to [Time_compat.now ()] — pass an explicit value in tests
    for deterministic output.  The counter guarantees uniqueness even when
    [now] is pinned to the same value across consecutive calls. *)
val keeper_name_from_agent_name : string -> string option
val is_keeper_agent_alias : string -> bool
val canonical_keeper_name_from_agent_name : string -> string option
val is_keeper_principal_agent_name : string -> bool
(** [is_keeper_principal_agent_name name] returns true for task-owner
    principals that should be treated as keeper-owned work: canonical
    [keeper-<name>-agent] aliases and dictionary-generated keeper nicknames.
    It intentionally rejects arbitrary three-part client names such as
    [codex-mcp-client]. *)
val canonical_keeper_name : string -> string option

val strip_keeper_prefix : string -> string option
(** [strip_keeper_prefix s] returns [Some suffix] if [s] starts with the
    literal ["keeper-"] prefix and the suffix after the prefix is non-empty;
    [None] otherwise.  Centralises the repeated [String.sub trimmed 0 7 =
    "keeper-"] check so callers no longer embed the literal — Phase A F5
    of the bloodflow restoration plan. *)

val keeper_agent_name : string -> string
(** [keeper_agent_name name] returns the canonical runtime agent name
    ["keeper-<name>-agent"], stripping one existing ["keeper-"] prefix first so
    callers do not double-prefix keeper names. *)

(** {1 Structural keeper identity (RFC-0232 §3.4)} *)

(** A canonical keeper identity minted once at the parse boundary.
    Replaces ad-hoc multi-form token-set intersection: any accepted
    identity shape (bare name, [keeper-X-agent] wrapper in any
    separator/case variant, generated nickname, [keeper-] prefix form)
    canonicalizes to one comparable value, and self-checks become
    {!Keeper_id.equal}.

    Not to be confused with the registry-level [Keeper_id] compilation
    unit ([lib/keeper_registry/keeper_id.ml]), whose [Uid] / [Trace_id]
    / [Task_id] wrap runtime instance identifiers — this module answers
    "who is this name?", that one answers "which run/task is this?". *)
module Keeper_id : sig
  type t = private string
  (** Canonical form: case-folded; wrapper/nickname forms reduced via
      {!canonical_keeper_name_from_agent_name} then
      {!canonical_keeper_name}; unrecognized inputs keep their
      case-folded raw form (non-keeper authors stay comparable). *)

  val of_string : string -> t option
  (** [None] iff the input is whitespace-only. *)

  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

type parsed_identity = {
  keeper_name : string;
  agent_name : string;
  trace_id : string option;
}

val parse_json_identity : Yojson.Safe.t -> parsed_identity

(** {1 SSOT keeper identity names (RFC P1)} *)

type name_bundle = {
  persona_name : string;
  keeper_name : string;
  agent_name : string;
}

type validation_error =
  | Empty_input
  | Persona_not_found of {
      input : string;
      resolved : string;
      searched : string;
    }
  | Name_ambiguous of { input : string; candidates : string list }
  | Ephemeral_suffix_rejected of { input : string; stripped : string }

val normalize_all_names :
  input_agent_name:string ->
  ?base_path:string ->
  ?check_persona:bool ->
  unit ->
  (name_bundle, validation_error) result
(** [normalize_all_names ~input_agent_name ?base_path ?check_persona ()]
    resolves the canonical name fields of a
    keeper from any of its accepted input shapes (bare name, [keeper-X-agent]
    wrapper, generated nickname like [executor-warm-raven], or wrapper +
    nickname combination).

    P1 default: [check_persona = false] — pure normalization without
    filesystem lookups. P3 preflight enables persona existence checks.

    [base_path] defaults to the empty string, which makes
    [Common.masc_dir_from_base_path] resolve relative to the current
    working directory. Tests must always pass an explicit [~base_path]. *)

val pp_validation_error : Format.formatter -> validation_error -> unit

val show_validation_error : validation_error -> string

val validation_error_outcome_label : validation_error -> string
(** Stable snake_case label for Otel_metric_store metric outcome labels
    ([masc_workspace_bind_normalize_outcome_total] in RFC P3-a). The
    pattern match is exhaustive so a new [validation_error] variant
    forces an update here rather than silently aggregating to an
    "unknown" bucket. *)
