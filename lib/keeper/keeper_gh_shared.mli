(** Shared GH primitives used by PR workflow handlers and keeper_shell op=gh.

    Contains the in-memory entity cache (hallucination gate), gh output
    handling (truncation + not-found hint), command parsers, and repo-slug
    utilities. Extracted from keeper_exec_github.ml to break up the god
    file; consumers now import this module rather than each other. *)

(* ---- Entity kind and cache ------------------------------------ *)

type entity_kind = PR | Issue

type validation_result =
  [ `Valid
  | `Invalid of int list
  | `Unknown
  ]

type task_repo_context = {
  task_id : string;
  git_root : string;
  repo_slug : string;
}

type task_repo_context_error =
  | Missing_current_task
  | Current_task_not_found of string
  | Current_task_missing_worktree of string
  | Current_task_origin_unavailable of {
      task_id : string;
      git_root : string;
    }
  | Current_task_origin_not_github of {
      task_id : string;
      git_root : string;
    }

(** Check whether [number] is a known-valid PR/issue for [repo_slug].
    On first call per [(repo_slug, kind)] the cache is populated via
    [gh api repos/{slug}/pulls|issues?state=all] (REST). Subsequent calls
    within the TTL (from [gh_cache.cache_ttl_sec]) are served from memory. *)
val validate_number :
  config:Coord.config ->
  repo_slug:string ->
  kind:entity_kind ->
  number:int ->
  validation_result

(** Clear the cache entry for [(repo_slug, kind)]. Called after a
    successful mutation (pr create, issue create, pr close) so the next
    validation picks up the new/removed number. *)
val invalidate_cache : repo_slug:string -> kind:entity_kind -> unit

(** Return [("hits", n); ("misses", n); ("bypasses", n); ("fetch_errors", n)]
    for the entity cache. *)
val cache_metrics : unit -> (string * int) list

(** Track and count repeated rejections for the same (repo, kind, number)
    tuple. Returns the current rejection count (1 on first rejection). *)
val record_rejection :
  repo_slug:string -> kind:entity_kind -> number:int -> int

(* ---- gh command output handling ------------------------------- *)

(** Return a [("hint", ...)] field when [st] is a non-zero exit and
    [out] matches a known "not found" error pattern from gh CLI. *)
val gh_not_found_hint :
  st:Unix.process_status ->
  out:string ->
  (string * Yojson.Safe.t) list

val max_gh_output_bytes : int

val truncate_gh_output :
  string -> string * (string * Yojson.Safe.t) list

(* ---- gh command parsers --------------------------------------- *)

type gh_command_parse_error =
  | Empty_command
  | Unsupported_shell_construct of string
  | Unsupported_command_shape of string

type gh_simple_command

(** Parse a single gh command shape into canonical argv (without the
    leading [gh] binary). Accepts both ["pr list"] and ["gh pr list"]
    input forms, but rejects pipelines, redirects, env prefixes, and
    other shell constructs outside the simple-command subset. *)
val parse_simple_gh_command :
  string -> (gh_simple_command, gh_command_parse_error) result

val gh_simple_command_argv : gh_simple_command -> string list

val render_simple_gh_command : gh_simple_command -> string

val gh_simple_command_has_repo_flag : gh_simple_command -> bool

val gh_simple_command_with_repo_flag :
  repo_slug:string ->
  gh_simple_command ->
  gh_simple_command

(** Pure parser: return the target [(kind, number)] when [cmd] is a gh
    subcommand that references a specific PR/issue number. *)
val extract_gh_target_number :
  string -> (entity_kind * int) option

(** Pure classifier: return [Some kind] when [cmd] is a mutation. *)
val gh_mutates_entity :
  string -> entity_kind option

(** Return [Some (error, required_tool, hint)] when a [keeper_shell op=gh]
    command targets PR mutations that must go through dedicated keeper PR
    tools rather than raw gh. *)
val dedicated_pr_tool_required :
  string -> (string * string * string) option

(** Deterministic safety classifier for destructive or credential-sensitive
    gh CLI commands. Ignores leading global flags like [--repo owner/name]
    before matching the command shape. Returns the canonical blocked pattern
    when [cmd] matches one of the blocked forms. *)
val gh_dangerous_command :
  string -> string option

(* ---- Repo slug + flag utilities ------------------------------- *)

val with_keeper_gh_env : Coord.config -> string -> string

val has_repo_flag : string -> bool

val is_valid_repo_segment : string -> bool

val validate_repo_slug : string -> (string, string) result

val strip_repo_flags_from_args : string list -> string list

val args_have_repo_flag : string list -> bool

val inject_repo_flag_args : repo_slug:string -> string list -> string list

val inject_repo_flag_cmd : repo_slug:string -> string -> string

val project_repo_slug : unit -> string option

val repo_slug_of_remote_url : string -> string option

val repo_slug_of_git_config : git_root:string -> string option

val repo_slug_of_task_worktree :
  git_root:string -> worktree_cwd:string -> string option

val resolve_task_repo_context :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  (task_repo_context, task_repo_context_error) result

val repo_slug_of_git_root : git_root:string -> string option
(** Replace a wrong --repo/-R slug in cmd with the correct one.
    Returns (corrected_cmd, was_corrected). *)
val correct_repo_flag :
  correct_slug:string -> string -> string * bool
