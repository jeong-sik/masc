<<<<<<< HEAD
(** RFC-0058: Declarative capability profile (v2).
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
(** Cascade_capability_profile — declarative capability requirement
    for cascade profiles.  RFC-0027.
=======
(** Cascade_capability_profile — declarative capability requirement
    for cascade profiles.  RFC-0027 (built-in) + RFC-0058 (TOML-defined).
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

<<<<<<< HEAD
    Profiles are string-named, resolved via
    {!Cascade_capability_schema}.  The previous closed variant
    [Tool_strict | Inline_tools | Lite | Local] has been removed;
    callers use profile name strings directly. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
    Each cascade in [cascade.toml] may declare a
    [required_capability_profile = "<name>"] field (added in PR #2).
    This module owns the closed enumeration of supported profile
    names, the capability-requirement table that defines each profile,
    and the predicate used by the validator to decide whether a
    given provider satisfies a profile.
=======
    Each cascade in [cascade.toml] may declare a
    [required_capability_profile = "<name>"] field (added in PR #2).
    This module owns the closed enumeration of built-in profile
    names, the TOML-driven profile registry for user-defined profiles,
    the capability-requirement table that defines each profile,
    and the predicate used by the validator to decide whether a
    given provider satisfies a profile.
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

<<<<<<< HEAD
val profile_to_string : string -> string
(** Identity function (profile names are already strings).
    Kept for API compatibility with callers that format profile names. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
    See: docs/rfc/RFC-0027-capability-typed-cascade.md *)
=======
    See: docs/rfc/RFC-0027-capability-typed-cascade.md,
         docs/rfc/RFC-0058-declarative-cascade-config.md *)
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

<<<<<<< HEAD
val profile_of_string : string -> string option
(** [profile_of_string s] returns [Some s] if [s] is a known profile
    name in {!Cascade_capability_schema.builtin_profiles}, [None]
    otherwise.  Unknown profile strings should be treated as a hard
    configuration error by callers. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
(** Closed enumeration of named capability profiles.  New variants
    require an explicit PR (deliberate — avoids silent string-typed
    drift between cascade.toml and code). *)
type profile =
  | Tool_strict
      (** Keeper-bound runtime MCP requires per-request HTTP headers.
          Only providers with [supports_runtime_mcp_http_headers]
          (claude_code / kimi_cli / HTTP-based) qualify.  Used by
          keepers that must dispatch keeper-scoped MCP tools (e.g.
          [keeper_bash], [masc_worktree_create]). *)
  | Inline_tools
      (** Direct-API path: provider must support [supports_inline_tools]
          and [supports_inline_tool_choice].  CLI runtimes
          (claude_code / codex_cli / gemini_cli / kimi_cli) all fail
          this — they expose tools through runtime MCP, not inline. *)
  | Lite
      (** Runtime-MCP-capable but does not require HTTP headers.
          Suitable for [gemini_cli] (static MCP via
          [~/.gemini/settings.json]) and other CLI runtimes that
          carry tools through stdio MCP. *)
  | Local_inline
      (** RFC-0058: Ollama-style providers with inline tool calling but
          no runtime MCP or tool_choice enforcement. Encodes the actual
          capability set of local LLM providers (inline_tools=Required,
          everything else Optional). Used as terminal fallback capability
          where graceful degradation is intentional. *)
  | Local
      (** No capability requirements — accepts any provider including
          ollama-only profiles.  Used by [local_recovery]-like lanes
          that exist purely for liveness fallback. *)
=======
(** Closed enumeration of built-in capability profiles.  New variants
    require an explicit PR (deliberate — avoids silent string-typed
    drift between cascade.toml and code).  User-defined profiles
    added via TOML [profiles.<name>] sections bypass this variant. *)
type profile =
  | Tool_strict
  | Inline_tools
  | Lite
  | Local_inline
  | Local
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

<<<<<<< HEAD
val all_profiles : string list
(** All builtin profile names from the schema registry. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
val profile_to_string : profile -> string
(** Stable lowercase snake_case label.
    [Tool_strict] -> ["tool_strict"], etc.  Used as the cascade.toml
    field value and the Prometheus label. *)

val profile_of_string : string -> profile option
(** Inverse of {!profile_to_string}.  Returns [None] for unknown
    strings — caller must treat that as a hard configuration error
    (no silent fallback). *)

val all_profiles : profile list
(** Every variant of {!profile} in declaration order.  Used by tests
    and by the validator to enumerate the catalog. *)

(** Per-capability requirement.  Mirrors the field set of
    {!Provider_tool_support.capabilities} but lifts each [bool] to
    a tri-state [requirement] so a profile can declare "I require
    this" vs. "I do not care". *)
type requirement =
  | Required
      (** Provider must have the capability set to [true]. *)
  | Optional
      (** Profile does not constrain this capability — provider may
          or may not have it. *)

type required_capabilities = {
  inline_tools : requirement;
  inline_tool_choice : requirement;
  runtime_mcp_tools : requirement;
  runtime_tool_events : requirement;
  runtime_mcp_http_headers : requirement;
}
(** The capability-requirement matrix for one profile.  Field names
    match {!Provider_tool_support.capabilities} (with the [supports_]
    prefix stripped) so satisfaction can be checked field-by-field. *)

val required_capabilities_of : profile -> required_capabilities
(** [required_capabilities_of p] returns the capability matrix that
    defines profile [p].  Pure function — see RFC-0027 §3.1 for the
    matrix definition. *)
=======
val profile_to_string : profile -> string
val profile_of_string : string -> profile option
val all_profiles : profile list

type requirement =
  | Required
  | Optional

type required_capabilities = {
  inline_tools : requirement;
  inline_tool_choice : requirement;
  runtime_mcp_tools : requirement;
  runtime_tool_events : requirement;
  runtime_mcp_http_headers : requirement;
}

val required_capabilities_of : profile -> required_capabilities
(** Built-in profile → capability matrix. *)
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

val provider_satisfies_profile :
<<<<<<< HEAD
  string -> Provider_tool_support.capabilities -> bool
(** [provider_satisfies_profile name caps] is [true] iff every
    capability required by profile [name] is [true] in [caps].
    Returns [false] for unknown profile names. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
  profile -> Provider_tool_support.capabilities -> bool
(** [provider_satisfies_profile p caps] is [true] iff every
    [Required] field of {!required_capabilities_of}[ p] is [true]
    in [caps].  [Optional] fields are unconstrained. *)
=======
  profile -> Provider_tool_support.capabilities -> bool

(** {2 RFC-0058: TOML-defined profiles} *)

type declared_profile = {
  required_capabilities_list : string list;
  provider_filter : string option;
}
(** A profile parsed from TOML [profiles.<name>] section.
    [required_capabilities_list] names must appear in
    [known_capability_fields]. *)

val known_capability_fields : string list
(** Canonical field names matching {!Provider_tool_support.capabilities}
    (with the [supports_] prefix stripped). *)

val register_declared_profiles_from_json :
  Yojson.Safe.t -> (unit, string) result
(** Parse the ["profiles"] JSON object produced by the TOML materializer
    and register each profile in the runtime registry.  Built-in
    profiles are not overwritten. *)

val resolve_required_capabilities :
  string -> required_capabilities option
(** [resolve_required_capabilities name] looks up built-in profiles
    first, then TOML-declared profiles.  Returns [None] if the name
    is unknown to both. *)

val resolve_provider_filter : string -> string option
(** [resolve_provider_filter name] returns the [provider_filter]
    declared in the TOML profile, or [None] if the profile is
    built-in or has no filter. *)

val provider_satisfies_named_profile :
  string -> Provider_tool_support.capabilities -> bool
(** String-based satisfaction check.  Resolves the profile name
    (built-in or declared), then checks capabilities.  Returns
    [false] for unknown profile names. *)

val required_capabilities_of_string_list :
  string list -> required_capabilities
(** Convert a list of capability field names to a capability matrix.
    Named fields are [Required]; unnamed fields are [Optional]. *)

val declared_profile_names : unit -> string list
(** Names of TOML-declared profiles currently in the runtime registry. *)

(** {2 System cascades} *)
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)

val safe_lane_cascade_name : string
<<<<<<< HEAD
(** System-only cascade name: ["__safe_lane"]. *)

||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
(** RFC-0027 PR-4 system-only cascade name, ["__safe_lane"].  This
    cascade is shipped in the seed [config/cascade.toml] and contains
    only providers that satisfy {!Tool_strict}.  Used as the absolute
    last-resort fallback target by the cross-cascade resolver.
    Operators must not assign this cascade to keepers — the [__]
    prefix marks it as system-internal and the seed sets
    [keeper_assignable = false]. *)

=======
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
val is_system_cascade_name : string -> bool
<<<<<<< HEAD
(** [is_system_cascade_name name] is [true] iff [name] starts with ["__"]. *)
||||||| parent of bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
(** [is_system_cascade_name name] is [true] iff [name] is a
    system-reserved cascade name (currently: anything starting with
    ["__"]).  Operator-authored cascades must not collide with this
    namespace. *)
=======
>>>>>>> bfa5059839 (feat(cascade): RFC-0058 Phase 1 — TOML-declared capability profiles + provider_filter)
