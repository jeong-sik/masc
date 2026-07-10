(** Path-only facts for keeper sandbox repositories.

    This module does not create directories, run git, repair repos, or decide
    Execute policy. It only classifies already-resolved filesystem paths against
    the keeper sandbox layout. *)

val normalize_path : string -> string

val playground_root_no_create :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> string

val candidate_repo_roots_no_create :
  base_path:string ->
  keeper_id:string ->
  repository_id:string ->
  string list
(** Candidate host-side sandbox repo roots for [repository_id] under
    [keeper_id]'s known sandbox backends. Returns [[]] when [repository_id] is
    not a safe single path component. This performs no filesystem mutation and
    does not require the keeper registry. *)

type path_context =
  { path_repo_name : string
  ; path_repo_root : string
  ; path_root : string
  ; accepted_toplevels : string list
  }
(** Path-only facts for any path inside a keeper sandbox repo. [path_root] is
    the repo root for the path. *)

val classify_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  path:string ->
  path_context option
(** Classify [path] as a keeper sandbox repo path. This performs no git probes
    and no repo setup. *)

type cwd_context =
  { repo_name : string
  ; repo_root : string
  ; path_root : string
  ; is_direct_root : bool
  }
(** Path-only facts for a cwd inside a keeper sandbox repo. [path_root] is the
    repo root expected for the cwd. *)

val classify_cwd :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  cwd:string ->
  cwd_context option
(** Classify [cwd] as a keeper sandbox repo cwd. This reports path facts only;
    callers own command-shape and write-gate policy. *)

val execution_location_json :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  args:Yojson.Safe.t ->
  cwd:string ->
  Yojson.Safe.t
(** Structured cwd contract for Execute responses. The JSON tells the agent
    whether the effective cwd is inside the keeper playground
    ([playground_root], [playground_subpath], [repo_root], [repo_subpath])
    or outside it ([outside_playground]). [relative_cwd] is relative to
    [playground_root] for playground scopes and [null] when the cwd is outside
    the playground. Relative argv paths resolve against the effective cwd. *)
