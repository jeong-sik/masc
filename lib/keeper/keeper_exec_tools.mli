open Keeper_types

val ensure_keeper_board_post_args :
  author:string -> source:string -> Yojson.Safe.t -> Yojson.Safe.t

val keeper_allowed_tool_names : ?write_done:bool -> keeper_meta -> string list
val keeper_allowed_model_tools :
  ?write_done:bool -> keeper_meta -> Types.tool_schema list

(** Inject all masc_* schemas for keeper allowlist/denylist filtering.
    Must be called once during server initialization.
    Keeper_denied tools are excluded at injection time. *)
val inject_masc_schemas : Types.tool_schema list -> unit

(** Check if a tool name is in the Keeper_denied surface (Tool_catalog).
    Denied tools are excluded from both the schema list sent to the LLM
    and blocked at execution time by the pre_tool_use hook. *)
val is_keeper_denied : string -> bool

(** Callback for recording keeper-internal tool calls.
    Set at server initialization to avoid Config dependency cycle. *)
val on_keeper_tool_call :
  (tool_name:string -> success:bool -> duration_ms:int -> unit) ref

(** masc_* tool names available for a keeper (filtered by allowlist/denylist). *)
val keeper_masc_tool_names : keeper_meta -> string list

(** masc_* tool schemas available for a keeper (filtered by allowlist/denylist). *)
val keeper_masc_tool_schemas : keeper_meta -> Types.tool_schema list

val execute_keeper_tool_call :
  config:Room.config ->
  meta:keeper_meta ->
  ctx_work:Keeper_working_context.working_context ->
  name:string ->
  input:Yojson.Safe.t ->
  string
