(** Agent task tool runtime — claim, transition, list. *)

val handle_keeper_task_tool :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  name:string ->
  args:Yojson.Safe.t ->
  string
