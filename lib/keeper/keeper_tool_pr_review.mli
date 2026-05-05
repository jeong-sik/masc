(** Keeper PR review tools — read, comment, reply handlers.

    Extracted from keeper_exec_github.ml. *)

(** Issue #8480: Variant SSOT for PR review event. Mirror in
    [Tool_shard.pr_review_event_enum_strings] (cycle avoidance). *)
type pr_review_event = Comment | Approve | Request_changes

val pr_review_event_to_string : pr_review_event -> string
val pr_review_event_of_string_opt : string -> pr_review_event option
val pr_review_event_to_gh_flag : pr_review_event -> string
val all_pr_review_events : pr_review_event list
val valid_pr_review_event_strings : string list
val pr_review_mutation_preset_ok : Keeper_types.tool_preset option -> bool

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
