(** Keeper PR workflow tool — multi-step PR creation handler.

    Extracted from keeper_exec_github.ml to break up that god file.
    Public surface is the single dispatch entry point consumed by
    [keeper_exec_tools]. *)

val handle_keeper_pr_workflow :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
