(** Path-only facts for keeper sandbox repositories.

    This module does not create directories, run git, repair repos, or decide
    Execute policy. It only classifies already-resolved filesystem paths against
    the keeper sandbox layout. *)

val normalize_path : string -> string

val playground_root_no_create :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> string

val execution_location_json :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  cwd:string ->
  Yojson.Safe.t
(** Keeper-visible structured cwd contract for Execute responses. The JSON
    tells the agent
    whether the effective cwd is inside the keeper playground
    ([playground_root], [playground_subpath], [repo_root], [repo_subpath])
    or outside it ([outside_playground]). [relative_cwd] is relative to
    [playground_root] for playground scopes and [null] when the cwd is outside
    the playground. Docker host-only absolute paths are projected into the
    mounted sandbox namespace or returned as [null]; Local paths retain their
    host namespace identity. Relative argv paths resolve against the effective
    cwd. *)
