open Keeper_types

val ensure_keeper_board_post_args :
  author:string -> source:string -> Yojson.Safe.t -> Yojson.Safe.t

val keeper_allowed_tool_names : ?write_done:bool -> keeper_meta -> string list
val keeper_allowed_model_tools :
  ?write_done:bool -> keeper_meta -> Types.tool_schema list

val execute_keeper_tool_call :
  config:Room.config ->
  meta:keeper_meta ->
  ctx_work:Context_manager.working_context ->
  name:string ->
  input:Yojson.Safe.t ->
  string
