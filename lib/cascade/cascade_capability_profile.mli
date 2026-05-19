(** RFC-0058: Declarative capability profile (v2).

    Profiles are string-named, resolved via
    {!Cascade_capability_schema}.  The previous closed variant
    [Tool_strict | Inline_tools | Lite | Local] has been removed;
    callers use profile name strings directly.

    Each cascade in [cascade.toml] may declare a
    [required_capability_profile = "<name>"] field (added in PR #2).
    This module owns the closed enumeration of built-in profile
    names, the TOML-driven profile registry for user-defined profiles,
    the capability-requirement table that defines each profile,
    and the predicate used by the validator to decide whether a
    given provider satisfies a profile.

    See: docs/rfc/RFC-0027-capability-typed-cascade.md,
         docs/rfc/RFC-0058-declarative-cascade-config.md *)

val profile_to_string : string -> string
(** Identity function (profile names are already strings).
    Kept for API compatibility with callers that format profile names. *)

val profile_of_string : string -> string option
(** [profile_of_string s] returns [Some s] if [s] is a known profile
    name in {!Cascade_capability_schema.builtin_profiles}, [None]
    otherwise.  Unknown profile strings should be treated as a hard
    configuration error by callers. *)

val all_profiles : string list
(** All builtin profile names from the schema registry. *)

val provider_satisfies_profile :
  string -> Provider_tool_support.capabilities -> bool
(** [provider_satisfies_profile name caps] is [true] iff every
    capability required by profile [name] is [true] in [caps].
    Returns [false] for unknown profile names.

    Checks built-in profiles only (via {!Cascade_capability_schema}).
    For declared profiles, use {!provider_satisfies_named_profile}. *)

(** {2 RFC-0058 Phase 1: TOML-declared profiles} *)

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

type declared_profile = {
  required_capabilities_list : string list;
  provider_filter : string option;
}

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

(** Why a {!provider_satisfies_named_profile} call could not produce a
    [bool] answer.  An unknown profile name is a config error (the
    operator typo'd a profile name in [cascade.toml] or a downstream
    pin removed a profile) — silently returning [false] would emit a
    misleading lint warning like "all models fail profile X" when the
    real issue is "profile X is unknown".  The [builtin] / [declared]
    fields list the two known pools separately so the diagnostic can
    say which side the name should have come from. *)
type named_profile_lookup_error =
  | Unknown_named_profile of
      { name : string; builtin : string list; declared : string list }

(** Format a {!named_profile_lookup_error} as a user-facing string for
    drop-in use in lint warnings and config error messages. *)
val named_profile_lookup_error_to_string :
  named_profile_lookup_error -> string

val provider_satisfies_named_profile :
  name:string ->
  Provider_tool_support.capabilities ->
  (bool, named_profile_lookup_error) result
(** [provider_satisfies_named_profile ~name caps] is [Ok true] iff
    [caps] satisfies every [Required] capability of profile [name],
    and [Ok false] when at least one [Required] capability is missing.
    Returns an [Error] when [name] is neither a built-in profile name
    ({!Cascade_capability_schema.all_profile_names}) nor a TOML-declared
    profile ({!declared_profile_names}); callers must not collapse the
    [Error] to [false] because the two cases imply different operator
    actions (fix profile name vs upgrade provider capabilities). *)

val required_capabilities_of_string_list :
  string list -> required_capabilities
(** Convert a list of capability field names to a capability matrix.
    Named fields are [Required]; unnamed fields are [Optional]. *)

val declared_profile_names : unit -> string list
(** Names of TOML-declared profiles currently in the runtime registry. *)

(** {2 System cascades} *)

val safe_lane_cascade_name : string
(** System-only cascade name: ["__safe_lane"]. *)

val is_system_cascade_name : string -> bool
(** [is_system_cascade_name name] is [true] iff [name] starts with ["__"]. *)
