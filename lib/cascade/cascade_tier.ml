(* RFC-0058: Capability-tier monotonicity for cascade fallback chains.

   A fallback edge source -> target is valid only if the target's
   capability profile is a superset of the source's profile.  This
   module provides the subset check used at config-load time.

   v2: Delegates to {!Cascade_capability_schema.is_subset_profile}
   for string-based profile comparison. *)

let is_subset_profile src_name dst_name =
  Cascade_capability_schema.is_subset_profile src_name dst_name
