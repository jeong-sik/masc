(** Dedicated GitHub PR keeper tools.

    These are intentionally narrower than [keeper_shell op=gh]: they run
    scoped [gh] argv commands after verifying the keeper/root GitHub
    credential bundle and keep PR creation draft-only. *)

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

val handle_keeper_pr_create :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

module For_testing : sig
  val build_pr_list_argv :
    repo:string -> state:string -> limit:int -> string list

  val build_pr_status_argv :
    repo:string -> pr_number:int -> string list

  val build_pr_create_argv :
    repo:string ->
    title:string ->
    body:string ->
    base:string option ->
    head:string option ->
    string list

  val draft_request_allowed : Yojson.Safe.t -> bool

  val quote_argv : string list -> string

  val mutation_preset_ok : Keeper_types.tool_preset option -> bool
  (** Mirrors the runtime gate in [handle_keeper_pr_create]. Exposed so
      regression tests can pin the visible/callable contract: any preset
      that grants the [github] group in [config/tool_policy.toml] must
      return [true] here. *)
end
