(** Keeper PR review tools — read, comment, reply handlers.

    Extracted from keeper_exec_github.ml. *)

(** Detect "PR not found" markers in [gh] CLI output (REST 404 + GraphQL
    "could not resolve"). Exposed for unit testing the parser; keepers
    consume the structured JSON returned by [handle_keeper_pr_review_read]. *)
val pr_not_found_in_output : string -> bool

val handle_keeper_pr_review_read :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_review_comment :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_review_reply :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
