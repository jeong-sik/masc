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
  remote_workspace_root:string ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  string -> string
(** Convert an SSH workspace path to internal containment coordinates. Relative
    and declared external paths retain their existing interpretation. The root
    must come from the same captured endpoint the operation will execute on. *)

val project_file_args :
  remote_workspace_root:string -> config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t -> Yojson.Safe.t
(** Project only structured [path] and [cwd] fields against the captured root.
    Program/script text is never changed. *)
