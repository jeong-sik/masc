(** Playground repository readiness.

    Owns repository clone readiness for playground repo lanes. Keeper
    execution code should treat this as the provisioning boundary rather than
    carrying repo lifecycle policy itself. *)

(** Stdout/stderr/exit triple for a [run_git] invocation. *)
type command_result =
  { ok : bool
  ; output : string
  ; status : Unix.process_status
  }

(** Run [git -C clone_path --no-optional-locks args] and capture exit/stdout.
    Hang protection is git's responsibility via [--no-optional-locks].
    Caller does not pass a timeout (PR #20479 spirit). *)
val run_git : clone_path:string -> string list -> command_result

(** Return a concise restore hint when [git status --porcelain] contains only
    tracked-file deletions, otherwise [None]. *)
val deleted_tracked_files_restore_hint : clone_path:string -> string option
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

(** Look up the repository URL from [repositories.toml] by registered id, name,
    or explicit alias. *)
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
