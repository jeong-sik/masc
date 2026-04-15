(** Shared GH primitives used by keeper_github + PR workflow handlers.

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

(** Check whether [number] is a known-valid PR/issue for [repo_slug].
    On first call per [(repo_slug, kind)] the cache is populated via
    [gh api repos/{slug}/pulls|issues?state=all] (REST). Subsequent calls
    within the TTL (from [gh_cache.cache_ttl_sec]) are served from memory. *)
val validate_number :
  config:Room.config ->
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

(** Pure parser: return the target [(kind, number)] when [cmd] is a gh
    subcommand that references a specific PR/issue number. *)
val extract_gh_target_number :
  string -> (entity_kind * int) option

(** Pure classifier: return [Some kind] when [cmd] is a mutation. *)
val gh_mutates_entity :
  string -> entity_kind option

(* ---- Repo slug + flag utilities ------------------------------- *)

val with_keeper_gh_env : Room.config -> string -> string

val has_repo_flag : string -> bool

val is_valid_repo_segment : string -> bool

val validate_repo_slug : string -> (string, string) result

val strip_repo_flags_from_args : string list -> string list

val args_have_repo_flag : string list -> bool

val inject_repo_flag_args : repo_slug:string -> string list -> string list

val project_repo_slug : unit -> string option

(** Replace a wrong --repo/-R slug in cmd with the correct one.
    Returns (corrected_cmd, was_corrected). *)
val correct_repo_flag :
  correct_slug:string -> string -> string * bool
