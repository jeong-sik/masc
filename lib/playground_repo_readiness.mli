(** Playground repository readiness.

    Owns repository clone/worktree readiness for playground repo lanes. Keeper
    execution code should treat this as the provisioning boundary rather than
    carrying repo lifecycle policy itself. *)

(** Stdout/stderr/exit triple for a [run_git] invocation. *)
type command_result =
  { ok : bool
  ; output : string
  ; status : Unix.process_status
  }

(** Read-only git probe timeout (seconds). Bumped to 15s in
    #9765/#9775 to absorb large-monorepo first-probe latency. *)
val read_only_probe_timeout_sec : float

(** Run [git -C clone_path --no-optional-locks args] with [timeout_sec].
    Trims the captured output. *)
val run_git :
  timeout_sec:float -> clone_path:string -> string list -> command_result

(** [safe_is_dir path] is [true] iff [path] exists and is a directory,
    swallowing [Sys_error]. *)
val safe_is_dir : string -> bool

(** Reject path-traversal-prone or special directory names. *)
val safe_repo_component : string -> bool

(** Project a free-form [repo] argument and the [project_root] to a
    bare repo name (basename, [.git] stripped). *)
val repo_name_of_repo_arg : project_root:string -> string -> string

(** Sandbox clone path for [repo_name] under a backend-scoped playground repos
    lane. *)
val clone_path :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  string

(** First non-empty line after trimming, or [None]. *)
val first_line_opt : string -> string option

(** Parse a [git rev-list --left-right --count] tab-separated pair
    into [Some (ahead, behind)] or [None]. *)
val parse_ahead_behind : string -> (int * int) option

(** Render an optional string as either [(name, `Null)] or
    [(name, `String value)]. *)
val string_opt_field :
  string -> string option -> (string * Yojson.Safe.t) list

(** Render an optional int as either [(name, `Null)] or
    [(name, `Int value)]. *)
val int_opt_field :
  string -> int option -> (string * Yojson.Safe.t) list

(** Probe the sandbox clone and return a JSON readiness report:
    [{ ok; state; keeper; repo; repo_name; clone_path; sandbox_repos;
       default_branch; next_action; exists; is_git_repo; ... }]. *)
val inspect :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?repo_name:string ->
  ?repo:string ->
  ?default_branch:string ->
  unit ->
  Yojson.Safe.t

(** Look up the repository URL from [repositories.toml] by repo name. *)
val find_repo_url :
  config:Workspace.config -> repo_name:string -> string option

(** [ensure_ready ~config ~meta ~repo_name ()] probes the sandbox repo
    via [inspect]. If the repo is [missing_clone] or [not_git_repo],
    attempts to clone it from the configured repository URL. Returns [Ok ()]
    when the repo is ready, or [Error msg] if repair failed or was not
    possible. *)
val ensure_ready :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  unit ->
  (unit, string) result

(** [ensure_worktree_ready ~config ~meta ~repo_name ~task_name ~worktree_path ()]
    ensures a git worktree exists at [worktree_path] inside the sandbox clone.
    If the worktree is missing, first ensures the parent repo is a valid git
    clone (reclone if needed), then creates the worktree from the fetched
    default origin branch. Parent clone dirtiness is preserved and does not block
    creating a separate task worktree. Returns [Ok ()] when the worktree is a
    valid git checkout, or [Error msg] if creation failed. *)
val ensure_worktree_ready :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  task_name:string ->
  worktree_path:string ->
  unit ->
  (unit, string) result

(** [provision_worktrees_for_task ~config ~agent_name ~task_id ()] scans all
    repos in the keeper's playground and creates a worktree for [task_id] in
    each repo that is ready.  Called best-effort at task claim time so worktrees
    exist before the LLM tries to use them.  Only operates for Docker-sandboxed
    keepers.  Failures in individual repos are logged but do not propagate. *)
val provision_worktrees_for_task :
  config:Workspace.config ->
  agent_name:string ->
  task_id:string ->
  unit ->
  unit

(** Outcome of an [ensure_current] pass. Every non-[Advanced] case leaves the
    working tree byte-for-byte untouched. *)
type currency_outcome =
  | Up_to_date
  | Advanced of int  (** fast-forwarded; payload = commits gained *)
  | Preserved of string
      (** dirty / detached / task branch / diverged — tree untouched, reason *)
  | Skipped of string
      (** not a ready clone / no credential or url / fetch failed — reason *)

(** [ensure_current ~config ~meta ~repo_name ()] fetches [origin] and
    fast-forwards the sandbox clone to [origin/<default_branch>] only when it is
    clean, on [default_branch], and a pure fast-forward. Dirty / detached /
    task-branch / diverged clones are left untouched ([Preserved]); uncommitted
    or unpushed work is never overwritten. Missing/corrupt clones return
    [Skipped] (repair is [ensure_ready]'s responsibility). [default_branch]
    defaults to ["main"]. *)
val ensure_current :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  ?default_branch:string ->
  unit ->
  currency_outcome
