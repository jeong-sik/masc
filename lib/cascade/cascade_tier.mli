(** Capability-tier monotonicity checks for cascade fallback chains. *)

val is_subset_profile :
  src:string ->
  dst:string ->
  (bool, Cascade_capability_schema.profile_lookup_error) result
(** [is_subset_profile ~src ~dst] re-exports
    {!Cascade_capability_schema.is_subset_profile} for callers that
    only want to depend on [Cascade_tier].  See that function's
    docstring for the [Error] semantics — an unknown profile name
    must not be silently collapsed to [false] (it is a config error,
    not a subset miss). *)

val requirement_leq :
  Cascade_capability_profile.requirement ->
  Cascade_capability_profile.requirement ->
  bool

val is_subset_caps :
  Cascade_capability_profile.required_capabilities ->
  Cascade_capability_profile.required_capabilities ->
  bool

val is_subset_named_profile :
  src:string ->
  dst:string ->
  (bool, Cascade_capability_schema.profile_lookup_error) result
(** [is_subset_named_profile ~src ~dst] performs the same kind of
    subset check as {!is_subset_profile} but resolves through
    {!Cascade_capability_profile.resolve_required_capabilities},
    which sees both built-in and TOML-declared profiles (RFC-0058
    Phase 1).  The [Error] branch's [known] field therefore lists
    the union of builtin + declared names at call time. *)
