(** Keeper repository readiness.

    Read-only probe for the single keeper sandbox repo clone under
    the keeper's backend-scoped sandbox repo lane. Tells preflight
    callers whether code work can safely start from that clone. *)

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

(** Sandbox clone path for [repo_name] under the keeper's
    backend-scoped repos lane. *)
val clone_path :
  config:Coord.config ->
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
  config:Coord.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?repo_name:string ->
  ?repo:string ->
  ?default_branch:string ->
  unit ->
  Yojson.Safe.t

(** Look up the repository URL from [repositories.toml] by repo name. *)
val find_repo_url :
  config:Coord.config -> repo_name:string -> string option

(** Resolve the keeper's mapped credential from [keeper_repo_mappings.toml]. *)
val resolve_keeper_credential :
  config:Coord.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (Repo_manager_types.credential, string) result

(** [ensure_ready ~config ~meta ~repo_name ()] probes the sandbox repo
    via [inspect]. If the repo is [missing_clone] or [not_git_repo],
    attempts to clone it from the configured repository URL using the
    keeper's mapped credential. Returns [Ok ()] when the repo is ready,
    or [Error msg] if repair failed or was not possible. *)
val ensure_ready :
  config:Coord.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  repo_name:string ->
  unit ->
  (unit, string) result
