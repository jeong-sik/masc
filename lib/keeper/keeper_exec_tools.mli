open Keeper_types

val ensure_keeper_board_post_args :
  author:string -> source:string -> Yojson.Safe.t -> Yojson.Safe.t

val keeper_allowed_tool_names : ?write_done:bool -> keeper_meta -> string list
val keeper_allowed_model_tools :
  ?write_done:bool -> keeper_meta -> Types.tool_schema list

(** Inject masc_* schemas for keeper profile-based tool filtering.
    Must be called once during server initialization. *)
val inject_masc_schemas : Types.tool_schema list -> unit

(** masc_* tool names available for a keeper profile. *)
val keeper_masc_tool_names : keeper_meta -> string list

(** masc_* tool schemas available for a keeper profile. *)
val keeper_masc_tool_schemas : keeper_meta -> Types.tool_schema list

val execute_keeper_tool_call :
  config:Room.config ->
  meta:keeper_meta ->
  ctx_work:Keeper_working_context.working_context ->
  name:string ->
  input:Yojson.Safe.t ->
  string
