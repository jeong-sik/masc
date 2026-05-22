(** Read-only GitHub PR keeper tools.

    These are intentionally narrower than [keeper_shell op=gh]: they run scoped
    read-only [gh] argv commands after verifying the keeper/root GitHub
    credential bundle. GitHub PR creation is not exposed as a keeper-native
    capability. *)

val handle_keeper_pr_list :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

val handle_keeper_pr_status :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

module For_testing : sig
  val build_pr_list_argv :
    repo:string -> state:string -> limit:int -> string list

  val build_pr_status_argv :
    repo:string -> pr_number:int -> string list

  val effective_repo_arg :
    config:Coord.config -> string -> (string, string) result

  val quote_argv : string list -> string
end
