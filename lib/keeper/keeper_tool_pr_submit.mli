(** Keeper PR submit tool — submits an already-prepared PR.

    Extracted from keeper_exec_github.ml. *)

val handle_keeper_pr_submit :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
