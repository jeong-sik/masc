(** Coord Worktree - Path / filesystem-shape helpers.

    Read-only path computations and shape checks.  No filesystem
    mutation; the only process execution is the [git rev-parse] used to
    confirm a usable worktree. *)

val is_git_repo : Coord_utils.config -> bool
(** [true] when [config.workspace_path] points to a git working tree. *)

val git_marker_kind : string -> [> `Directory | `File | `Missing ]
(** Classify the [.git] entry at [path]. *)

val project_root : Coord_utils.config -> String.t
(** Canonical absolute path of the project root for [config]. *)

val require_repository_root_with_git :
  Coord_utils.config -> (String.t, Masc_domain.masc_error) result
(** Resolve a usable repository root or fail with a structured error. *)

val ensure_worktree_path :
  string -> string -> (string * string, Masc_domain.masc_error) result
(** Return [(absolute, relative)] paths under [<root>/.worktrees/<name>]. *)

val safe_file_exists : string -> bool
val safe_is_dir : string -> bool

val safe_repo_name : string -> bool
(** [true] iff [name] is a single repo-name segment. *)

val worktree_mutation_mutex : Eio.Mutex.t
val with_worktree_mutation_lock : (unit -> 'a) -> 'a

val is_git_clone : string -> bool
val has_git_marker : string -> bool
val same_realpath : String.t -> String.t -> bool
val is_usable_git_worktree : String.t -> bool
val current_worktree_branch : String.t -> String.t option
val run_git_in_clone :
  string -> string list -> Unix.process_status * string

val trim_output_detail : string -> string
val first_nul_field : string -> string option

val keeper_toml_path :
  config:Coord_utils.config -> agent_name:string -> string
val strip_inline_comment : string -> string
val unquote : string -> string
val keeper_uses_docker_sandbox :
  config:Coord_utils.config -> agent_name:string -> bool
val repos_dir_of_keeper : Coord_utils.config -> string -> string

val strip_trailing_slashes : string -> string
val suffix_under : prefix:string -> string -> string option

val keeper_visible_worktree_path :
  config:Coord_utils.config -> agent_name:string -> host_path:string -> string

val worktree_next_step : string -> string
