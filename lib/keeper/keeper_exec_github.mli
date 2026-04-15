(** Keeper GitHub tool handlers — git commands, PR workflow, and the
    inlined GH entity cache (hallucination gate for PR/issue numbers). *)

(** PR/issue kind for the hallucination gate and mutation invalidation. *)
type entity_kind = PR | Issue

(** Validation outcome from the inlined GH entity cache. *)
type validation_result =
  [ `Valid
  | `Invalid of int list  (** number not in cache; valid alternatives returned *)
  | `Unknown              (** cache fetch failed or empty; caller proceeds *)
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
    for the inlined entity cache. *)
val cache_metrics : unit -> (string * int) list

(** Return a [("hint", `String ...)] field when [st] is a non-zero exit
    and [out] matches a known "not found" error pattern from gh CLI.
    Returns [[]] otherwise. Useful for detecting hallucinated issue/PR
    numbers. *)
val gh_not_found_hint :
  st:Unix.process_status ->
  out:string ->
  (string * Yojson.Safe.t) list

val max_gh_output_bytes : int

val truncate_gh_output :
  string ->
  string * (string * Yojson.Safe.t) list

(** Pure parser: return the target [(kind, number)] when [cmd] is a gh
    subcommand that references a specific PR/issue number. Returns
    [None] for list/create/status commands and for branch-name-style
    targets (e.g. "pr view my-branch"). Exposed for unit testing. *)
val extract_gh_target_number :
  string -> (entity_kind * int) option

(** Pure classifier: return [Some kind] when [cmd] is a mutation that
    changes the set of PRs/issues (create/close/reopen/merge/etc.).
    Used to invalidate the gh cache after a successful mutation.
    Exposed for unit testing. *)
val gh_mutates_entity :
  string -> entity_kind option

val handle_keeper_github :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_workflow :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_submit :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_review_read :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_review_comment :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_review_reply :
  config:Room.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
