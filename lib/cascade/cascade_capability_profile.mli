(** RFC-0058: Declarative capability profile (v2).

    Profiles are string-named, resolved via
    {!Cascade_capability_schema}.  The previous closed variant
    [Tool_strict | Inline_tools | Lite | Local] has been removed;
    callers use profile name strings directly. *)

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
    Returns [false] for unknown profile names. *)

val safe_lane_cascade_name : string
(** System-only cascade name: ["__safe_lane"]. *)

val is_system_cascade_name : string -> bool
(** [is_system_cascade_name name] is [true] iff [name] starts with ["__"]. *)
