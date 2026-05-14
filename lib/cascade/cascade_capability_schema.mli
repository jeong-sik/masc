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

val is_subset_profile : string -> string -> bool
(** [is_subset_profile src dst] is [true] iff every capability required
    by [src] is also required by [dst].  Returns [false] if either
    profile name is unknown. *)
