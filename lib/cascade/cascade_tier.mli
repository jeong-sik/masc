(** Capability-tier monotonicity checks for cascade fallback chains. *)

val is_subset_profile : string -> string -> bool

val requirement_leq :
  Cascade_capability_profile.requirement ->
  Cascade_capability_profile.requirement ->
  bool

val is_subset_caps :
  Cascade_capability_profile.required_capabilities ->
  Cascade_capability_profile.required_capabilities ->
  bool

val is_subset_named_profile : string -> string -> bool
