(** RFC-0058: Config-driven capability profile schema.

    String-based profile lookup replacing closed OCaml variant.
    See {!Cascade_capability_schema} for details. *)

type capability_level = Verified | Declared | Unsupported
(** Graduated trust level for model-level capability declarations.
    Phase 1 feature; Phase 0 uses {!Provider_tool_support} directly. *)

type profile_spec = {
  required_capabilities : string list;
  provider_filter : string option;
}
(** A profile defined by a list of required capability names and an
    optional provider kind filter.  Capability names must appear in
    {!known_capability_fields}. *)

val known_capability_fields : (string * (Provider_tool_support.capabilities -> bool)) list
(** Registry of known capability names and their accessors into
    {!Provider_tool_support.capabilities}.  Add new entries here when
    {!Provider_tool_support.capabilities} gains a new field. *)

val capability_field_of_string :
  string -> (Provider_tool_support.capabilities -> bool, string) result
(** [capability_field_of_string name] returns the getter function for
    capability [name], or [Error msg] if [name] is not in
    {!known_capability_fields}. *)

val provider_satisfies_required :
  Provider_tool_support.capabilities -> string list -> bool
(** [provider_satisfies_required caps names] is [true] iff every named
    capability in [names] is [true] in [caps].  Unknown names are
    treated as unsatisfied (fail-closed). *)

val builtin_profiles : (string * profile_spec) list
(** The 4 builtin profiles matching the previous closed variant
    behavior: [tool_strict], [inline_tools], [lite], [local]. *)

val resolve_profile : string -> profile_spec option
(** [resolve_profile name] returns the profile spec for [name],
    or [None] if no builtin profile matches. *)

val all_profile_names : string list
(** All builtin profile names. *)

val is_known_profile : string -> bool
(** [is_known_profile name] checks whether [name] matches a builtin. *)

(** Why a {!is_subset_profile} call could not produce a [bool] answer.
    Returned as the [Error] branch instead of being silently collapsed
    to [false] so callers (config validators, RFC-0058 wiring,
    diagnostics) can surface an actionable message that names the
    offending profile and lists the known pool. *)
type profile_lookup_error =
  | Unknown_source_profile of { name : string; known : string list }
  | Unknown_destination_profile of { name : string; known : string list }
  | Unknown_both_profiles of { src : string; dst : string; known : string list }

(** Format a {!profile_lookup_error} as a user-facing string.  The known
    pool is rendered comma-separated so the message can be dropped into
    a lint warning, log line, or config error verbatim. *)
val profile_lookup_error_to_string : profile_lookup_error -> string

val is_subset_profile :
  src:string -> dst:string -> (bool, profile_lookup_error) result
(** [is_subset_profile ~src ~dst] is [Ok true] iff every capability
    required by profile [src] is also required by profile [dst], and
    [Ok false] if at least one capability in [src] is not required by
    [dst].  If either profile name is unknown, returns an [Error] that
    names which side(s) failed lookup and lists the known builtin
    profile names; callers must not silently collapse this to [false]
    because an unknown profile is a config error (not a real subset
    miss) and operators need to see which profile name was wrong. *)
