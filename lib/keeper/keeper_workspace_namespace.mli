(** Resolve the model's workspace namespace at the configuration edge, without
    connecting, probing, creating directories or constructing a runner. *)
val resolve :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  profile_defaults:Keeper_types_profile.keeper_profile_defaults ->
  (string, string) result
(** Uses the admitted profile snapshot's endpoint name. SSH roots come from
    that named endpoint; unknown or absent declarations return a named error.
    Docker uses its mounted root; microVM retains its bookkeeping namespace. *)

val project_input :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  string -> (string, string) result
(** Convert an SSH workspace path to internal containment coordinates. Relative
    and declared external paths retain their existing interpretation. Endpoint
    resolution errors are returned, never replaced with a host fallback. *)
