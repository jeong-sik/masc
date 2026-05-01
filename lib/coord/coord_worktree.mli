(** Coord Worktree - Git Worktree Integration for Agent Isolation.

    MASC v2 feature: each agent works in an isolated git worktree to prevent
    file conflicts during parallel work.  Public surface covers worktree
    create/remove/list, sandbox clone provisioning, and the helpers used by
    [Task_sandbox], [Keeper_repo_readiness], and [Keeper_exec_shell].

    Extracted from [room.ml] for modularity. *)

(** {1 Argv-only exec helpers}

    These wrap [Masc_exec.Exec_gate.run_argv*] with a fixed actor tag and
    [coord/worktree] summary so all git plumbing emits a consistent audit
    trail.  Default timeout is the short
    {!Env_config_runtime.Coord_git.local_op_timeout_sec}; fetch-class
    operations must pass an explicit longer budget. *)

val exec_gate_raw_source : string list -> string
(** [exec_gate_raw_source argv] renders [argv] as a quoted shell-string for
    the audit/raw_source field; never executed as a shell command. *)

val run_argv_lines : string list -> string list
(** Run [argv] (no shell) and return non-empty stdout lines. *)

val run_argv_with_status :
  ?timeout_sec:float -> string list -> Unix.process_status * string
(** Run [argv] and return [(status, combined_output)].  See module-level
    docstring for [timeout_sec] semantics. *)

val run_argv_exit : ?timeout_sec:float -> string list -> int
(** Run [argv] and return the exit code (128 for signaled/stopped). *)

(** {1 Output / parsing helpers} *)

val first_nonempty_line : string -> string option
(** First non-empty trimmed line from [output], or [None] if every line is
    blank. *)

val policy_string_array_of_line :
  key:string -> string -> string list option
(** Parse a TOML-ish [key = ["a", "b"]] line into a list of strings.
    Returns [None] when [key] doesn't match or the array is malformed. *)

val load_git_clone_policy :
  base_path:string -> string list * string list
(** Load [(allowed_orgs, denied_repos)] from [tool_policy.toml].  Canonical
    [<base_path>/.masc/config/tool_policy.toml] takes priority over legacy
    [<base_path>/config/tool_policy.toml].  Returns empty lists when the file
    is missing for compatibility; enforcement uses a fail-closed result loader
    internally. *)

(** {1 GitHub URL parsing} *)

val extract_github_org_repo : string -> string option
(** [extract_github_org_repo url] returns ["org/repo"] for any GitHub
    [https://] or [git@] URL, or [None] for non-GitHub URLs. *)

val extract_github_org : string -> string option
(** [extract_github_org url] returns the org slug for a GitHub URL. *)

val validate_clone_origin_url :
  base_path:string -> string -> (unit, string) result
(** Validate [origin_url] against the policy at [base_path].  Used before
    auto-provisioning a sandbox clone from a workspace repo.  Missing policy
    fails closed; an explicitly empty [allowed_orgs] list allows any supported
    GitHub ["org/repo"] URL subject to [denied_repos]. *)

(** {1 Repository discovery / shape checks} *)

val is_git_repo : Coord_utils.config -> bool
(** [true] when [config.workspace_path] points to a git working tree
    (regular checkout, worktree, or bare). *)

val git_marker_kind : string -> [> `Directory | `File | `Missing ]
(** Classify the [.git] entry at [path]: directory (regular checkout),
    file (linked worktree), or missing. *)

val project_root : Coord_utils.config -> String.t
(** Canonical absolute path of the project root for [config]. *)

val require_repository_root_with_git :
  Coord_utils.config -> (String.t, Types.masc_error) result
(** Resolve a usable repository root or fail with a structured
    [Types.masc_error] explaining why the path is not a git repo. *)

val ensure_worktree_path :
  string -> string -> (string * string, Types.masc_error) result
(** [ensure_worktree_path root worktree_name] returns [(absolute, relative)]
    paths under [<root>/.worktrees/<worktree_name>], creating the
    [.worktrees/] parent if necessary. *)

(** {1 Filesystem safety helpers} *)

val safe_file_exists : string -> bool
(** [Sys.file_exists] guarded against EACCES / broken symlinks. *)

val safe_is_dir : string -> bool
(** [Sys.is_directory] guarded against EACCES / broken symlinks. *)

val safe_repo_name : string -> bool
(** [true] iff [name] is a single repo-name segment (no slashes, no
    traversal, [A-Za-z0-9._-] characters only).  Rejects ["."] and [".."]
    even though they pass the character class. *)

(** {1 Mutation serialization}

    All worktree create/remove operations serialize on a single Eio mutex
    so concurrent fibers cannot interleave [git worktree add] / [remove]. *)

val worktree_mutation_mutex : Eio.Mutex.t
(** The lock used by [with_worktree_mutation_lock]. *)

val with_worktree_mutation_lock : (unit -> 'a) -> 'a
(** Run [f] under [worktree_mutation_mutex]. *)

(** {1 Sandbox clone shape} *)

val is_git_clone : string -> bool
(** [true] when [path] looks like a regular (non-worktree) git checkout. *)

val same_realpath : String.t -> String.t -> bool
(** [true] when both paths resolve to the same canonical realpath. *)

val is_usable_git_worktree : String.t -> bool
(** [true] when [path] is a linked git worktree whose checkout is intact. *)

val run_git_in_clone :
  string -> string list -> Unix.process_status * string
(** Run [git <args>] inside the clone at [path] (no [-C] when path is the
    cwd).  Returns [(status, combined_output)]. *)

val trim_output_detail : string -> string
(** Trim and collapse whitespace for inclusion in error messages. *)

val first_nul_field : string -> string option
(** First NUL-delimited field, used to parse [git ls-files -z]. *)

(** {1 Sandbox clone repair} *)

type sandbox_clone_state =
  | Ready
      (** Clone is a usable git checkout with all tracked files present. *)
  | Needs_checkout of string
      (** A tracked path is missing on disk; [git checkout -f] would fix. *)
  | Broken_git of string
      (** Clone is unusable as a git directory; details in the payload. *)
(** State of a sandbox clone candidate, returned by
    {!inspect_sandbox_clone}. *)

val inspect_sandbox_clone : String.t -> sandbox_clone_state
(** Determine the [sandbox_clone_state] of a candidate path. *)

val restore_sandbox_clone_checkout :
  String.t -> (string option, Types.masc_error) result
(** Attempt [git checkout -f HEAD -- .] on a clone whose tracked files
    drifted.  [Ok (Some msg)] on success with an audit message; [Error _]
    if recovery still failed. *)

val ensure_sandbox_clone_ready :
  String.t -> (string option, Types.masc_error) result
(** [Ok None] if the clone is already [Ready]; otherwise tries
    [restore_sandbox_clone_checkout] and returns its result. *)

(** {1 Per-keeper sandbox configuration}

    Sandbox clones live under [<base_path>/repos/<keeper>/<repo_name>/] and
    are gated by a [docker_sandbox] flag in the keeper's
    [keepers/<keeper>/keeper.toml].  These helpers parse the TOML
    minimally — no full TOML library — to keep the dependency footprint
    small. *)

val keeper_toml_path :
  config:Coord_utils.config -> agent_name:string -> string
(** Absolute path of [keepers/<agent_name>/keeper.toml] for [config]. *)

val strip_inline_comment : string -> string
(** Remove a trailing [#] comment from a TOML line, respecting quoted
    strings. *)

val unquote : string -> string
(** Strip matching surrounding quotes from a TOML value, leaving unquoted
    values unchanged. *)

val keeper_uses_docker_sandbox :
  config:Coord_utils.config -> agent_name:string -> bool
(** [true] when the keeper's TOML has [docker_sandbox = true]. *)

val repos_dir_of_keeper : Coord_utils.config -> string -> string
(** Per-keeper sandbox repo directory:
    [<base_path>/repos/<agent_name>/]. *)

val rm_rf : string -> unit
(** Recursively remove [path]; silently no-op when [path] is missing. *)

(** {1 Structured error builders}

    Centralised so caller-facing messages stay consistent across
    [worktree_create_r], [auto_provision_sandbox_clone], and the dashboard
    diagnostics surface. *)

val missing_sandbox_clone_error :
  agent_name:string ->
  repos_dir:string -> repo_name:string option -> Types.masc_error
(** Sandbox clone is required but [repos_dir] has no matching clone. *)

val workspace_repo_not_found_error :
  agent_name:string ->
  repos_dir:string ->
  repo_name:string -> search_root:string -> Types.masc_error
(** Auto-provisioning fallback failed: no workspace repo named [repo_name]
    exists under [search_root]. *)

val workspace_repo_ambiguous_error :
  repo_name:string ->
  search_root:string -> matches:string list -> Types.masc_error
(** Auto-provisioning fallback failed: more than one workspace repo
    matches [repo_name]. *)

val partial_clone_error : clone_path:string -> msg:string -> Types.masc_error
(** Sandbox clone exists but is in an unusable state. *)

(** {1 Workspace repo discovery} *)

val workspace_repo_matches :
  search_root:String.t -> repo_name:string -> String.t list
(** Return absolute paths of every directory under [search_root] whose
    basename equals [repo_name] and which looks like a git checkout. *)

val git_origin_url : string -> string option
(** [git -C root config --get remote.origin.url], or [None] if unset. *)

val auto_provision_sandbox_clone :
  config:Coord_utils.config ->
  agent_name:string ->
  repos_dir:string ->
  repo_name:string -> (string * string option, Types.masc_error) result
(** Provision a sandbox clone under [repos_dir] from a discoverable
    workspace repo, gated by {!validate_clone_origin_url}.  Returns
    [(clone_path, audit_msg)] on success. *)

(** {1 Worktree lifecycle (public API)} *)

val link_worktree_to_task :
  Coord_utils_backend_setup.config ->
  task_id:string ->
  worktree_info:Types.worktree_info -> (unit, Types.masc_error) result
(** Persist the worktree↔task association so [tool_worktree_status] and
    the dashboard can resolve a worktree from a task id. *)

val worktree_create_r :
  ?link_task:bool ->
  ?repo_name:string ->
  Coord_utils.config ->
  agent_name:string ->
  task_id:string -> base_branch:string -> string Types.masc_result
(** Create [<root>/.worktrees/<task_id>] tracking [base_branch] for
    [agent_name].  Auto-provisions the sandbox clone when missing and
    [docker_sandbox = true]. If [repo_name] is omitted, selects the repo
    from task repo/path evidence, falling back only when exactly one clone
    exists. Ambiguous multi-repo sandboxes fail instead of picking an
    arbitrary clone. Returns the absolute worktree path on success. *)

val worktree_remove_r :
  Coord_utils.config ->
  agent_name:string -> task_id:string -> string Types.masc_result
(** Remove the worktree previously created for [(agent_name, task_id)]
    and unlink the task association.  Idempotent. *)

val worktree_list : Coord_utils.config -> Yojson.Safe.t
(** JSON snapshot of every worktree currently tracked under [config],
    suitable for dashboard / [masc_worktree_list] tool output. *)
