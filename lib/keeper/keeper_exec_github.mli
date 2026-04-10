(** Keeper GitHub tool handlers — git commands and PR workflow. *)

(** Return a [("hint", `String ...)] field when [st] is a non-zero exit
    and [out] matches a known "not found" error pattern from gh CLI.
    Returns [[]] otherwise. Useful for detecting hallucinated issue/PR
    numbers. *)
val gh_not_found_hint :
  st:Unix.process_status ->
  out:string ->
  (string * Yojson.Safe.t) list

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
