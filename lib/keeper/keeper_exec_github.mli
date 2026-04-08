(** Keeper GitHub tool handlers — git commands and PR workflow. *)

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
