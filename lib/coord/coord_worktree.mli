(** Coord Worktree - Git Worktree Integration for Agent Isolation *)

val exec_gate_raw_source : string list -> string
val run_argv_lines : string list -> string list
val run_argv_with_status : ?timeout_sec:float -> string list -> Unix.process_status * string
val run_argv_exit : ?timeout_sec:float -> string list -> int
val first_nonempty_line : string -> string option
val policy_string_array_of_line : key:string -> string -> string list option
val load_git_clone_policy : base_path:string -> string list * string list
val extract_github_org_repo : string -> string option
val extract_github_org : string -> string option
val validate_clone_origin_url : base_path:string -> string -> (unit, string) result
val is_git_repo : Coord_utils_backend_setup.config -> bool
val git_marker_kind : string -> [> `Directory | `File | `Missing ]
val project_root : Coord_utils_backend_setup.config -> string
val require_repository_root_with_git : Coord_utils_backend_setup.config -> (string, Types.masc_error) result
val ensure_worktree_path : string -> string -> (string * string, Types.masc_error) result
val safe_file_exists : string -> bool
val safe_is_dir : string -> bool
val safe_repo_name : string -> bool
val worktree_mutation_mutex : Eio.Mutex.t
val with_worktree_mutation_lock : (unit -> 'a) -> 'a
val is_git_clone : string -> bool
val same_realpath : string -> string -> bool
val is_usable_git_worktree : string -> bool
val run_git_in_clone : string -> string list -> Unix.process_status * string
val trim_output_detail : string -> string
val first_nul_field : string -> string option

type sandbox_clone_state =
  | Ready
  | Needs_checkout of string
  | Broken_git of string

val inspect_sandbox_clone : string -> sandbox_clone_state
val restore_sandbox_clone_checkout : string -> (string option, Types.masc_error) result
val ensure_sandbox_clone_ready : string -> (string option, Types.masc_error) result
val keeper_toml_path : config:Coord_utils_backend_setup.config -> agent_name:string -> string
val strip_inline_comment : string -> string
val unquote : string -> string
val keeper_uses_docker_sandbox : config:Coord_utils_backend_setup.config -> agent_name:string -> bool
val repos_dir_of_keeper : Coord_utils_backend_setup.config -> string -> string
val rm_rf : string -> unit
val missing_sandbox_clone_error : agent_name:string -> repos_dir:string -> repo_name:string option -> Types.masc_error
val workspace_repo_not_found_error : agent_name:string -> repos_dir:string -> repo_name:string -> search_root:string -> Types.masc_error
val workspace_repo_ambiguous_error : repo_name:string -> search_root:string -> matches:string list -> Types.masc_error
val partial_clone_error : clone_path:string -> msg:string -> Types.masc_error
val workspace_repo_matches : search_root:string -> repo_name:string -> string list
val git_origin_url : string -> string option
val auto_provision_sandbox_clone : config:Coord_utils_backend_setup.config -> agent_name:string -> repos_dir:string -> repo_name:string -> (string * string option, Types.masc_error) result
val link_worktree_to_task : Coord_utils_backend_setup.config -> task_id:string -> worktree_info:Types.worktree_info -> (unit, Types.masc_error) result
val worktree_create_r : ?link_task:bool -> ?repo_name:string -> Coord_utils_backend_setup.config -> agent_name:string -> task_id:string -> base_branch:string -> string Types.masc_result
val worktree_remove_r : Coord_utils_backend_setup.config -> agent_name:string -> task_id:string -> string Types.masc_result
val worktree_list : Coord_utils_backend_setup.config -> Yojson.Safe.t