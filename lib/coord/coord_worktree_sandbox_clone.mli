(** Coord Worktree - Sandbox clone state & auto-provision. *)

type sandbox_clone_state =
  | Ready
      (** Clone is a usable git checkout with all tracked files present. *)
  | Needs_checkout of string
      (** A tracked path is missing on disk; [git checkout -f] would fix. *)
  | Broken_git of string
      (** Clone is unusable as a git directory; details in the payload. *)

val inspect_sandbox_clone : String.t -> sandbox_clone_state

val restore_sandbox_clone_checkout :
  String.t -> (string option, Masc_domain.masc_error) result

val ensure_sandbox_clone_ready :
  String.t -> (string option, Masc_domain.masc_error) result

val missing_sandbox_clone_error :
  agent_name:string ->
  repos_dir:string ->
  repo_name:string option ->
  Masc_domain.masc_error

val workspace_repo_not_found_error :
  agent_name:string ->
  repos_dir:string ->
  repo_name:string ->
  search_root:string ->
  Masc_domain.masc_error

val workspace_repo_ambiguous_error :
  repo_name:string ->
  search_root:string ->
  matches:string list ->
  Masc_domain.masc_error

val partial_clone_error :
  clone_path:string -> msg:string -> Masc_domain.masc_error

val normalize_origin_remote_to_https : string -> string option
(** Internal helper used by lifecycle to keep origin URLs canonical
    before fetching.  Returns the new URL on rewrite, [None] otherwise. *)

val auto_provision_sandbox_clone :
  config:Coord_utils.config ->
  agent_name:string ->
  repos_dir:string ->
  repo_name:string ->
  (string * string option, Masc_domain.masc_error) result
