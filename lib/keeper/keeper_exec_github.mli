(** Keeper GitHub tool handlers — git commands and PR workflow. *)

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
  string -> (Keeper_gh_cache.entity_kind * int) option

(** Pure classifier: return [Some kind] when [cmd] is a mutation that
    changes the set of PRs/issues (create/close/reopen/merge/etc.).
    Used to invalidate the gh cache after a successful mutation.
    Exposed for unit testing. *)
val gh_mutates_entity :
  string -> Keeper_gh_cache.entity_kind option

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
