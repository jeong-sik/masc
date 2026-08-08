(** MCP (Model Context Protocol) client.

    Spawns an MCP subprocess and communicates via JSON-RPC 2.0 NDJSON
    over stdin/stdout. Handles tool invocation, resource listing,
    and prompt fetching.

    @stability Internal
    @since 0.93.1 *)

(** {1 Re-exported schema types} *)

(** Re-exports from {!Mcp_schema}. *)

type mcp_tool = Mcp_schema.mcp_tool =
  { name : string
  ; description : string
  ; input_schema : Yojson.Safe.t
  }

type mcp_resource = Mcp_schema.mcp_resource
type mcp_resource_contents = Mcp_schema.mcp_resource_contents
type mcp_prompt = Mcp_schema.mcp_prompt
type mcp_prompt_result = Mcp_schema.mcp_prompt_result

val json_schema_type_to_param_type : string -> Types.param_type
val json_schema_type_to_param_type_result : string -> (Types.param_type, string) result
val json_schema_to_params : Yojson.Safe.t -> Types.tool_param list
val json_schema_to_params_result : Yojson.Safe.t -> (Types.tool_param list, string) result
val mcp_tool_of_sdk_tool : Mcp_schema.Sdk_types.tool -> mcp_tool

(** Re-export of {!Mcp_schema.tool_of_input_schema_result}: derives the
    parameter view from [~input_schema] and keeps that schema as the
    authoritative wire form, so the two can never disagree. *)
val tool_of_input_schema_result
  :  ?descriptor:Tool.descriptor
  -> ?strict:bool
  -> name:string
  -> description:string
  -> input_schema:Yojson.Safe.t
  -> (Yojson.Safe.t -> Types.tool_result)
  -> (Tool.t, string) result

val mcp_tool_to_sdk_tool
  :  call_fn:(Yojson.Safe.t -> Types.tool_result)
  -> mcp_tool
  -> Tool.t

val mcp_tool_to_sdk_tool_result
  :  call_fn:(Yojson.Safe.t -> Types.tool_result)
  -> mcp_tool
  -> (Tool.t, string) result

val mcp_tool_of_json : Yojson.Safe.t -> mcp_tool option

(** {1 Client handle} *)

type t

(** {1 Connection lifecycle} *)

val connect
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> command:string
  -> args:string list
  -> ?env:string array
  -> unit
  -> (t, Error.sdk_error) result

val initialize : t -> (unit, Error.sdk_error) result
val close : t -> unit
val is_alive : t -> bool

(** {1 Tool operations} *)

val list_tools : t -> (mcp_tool list, Error.sdk_error) result
val call_tool : t -> name:string -> arguments:Yojson.Safe.t -> Types.tool_result
val to_tools : t -> mcp_tool list -> (Tool.t list, Error.sdk_error) result

(** {1 Resource and prompt operations} *)

val list_resources : t -> (Mcp_schema.mcp_resource list, Error.sdk_error) result

val read_resource
  :  t
  -> uri:string
  -> (Mcp_schema.mcp_resource_contents list, Error.sdk_error) result

val list_prompts : t -> (Mcp_schema.mcp_prompt list, Error.sdk_error) result

val get_prompt
  :  t
  -> name:string
  -> ?arguments:(string * string) list
  -> unit
  -> (Mcp_schema.mcp_prompt_result, Error.sdk_error) result

(** {1 Managed connections} *)
val text_of_tool_result : Mcp_schema.Sdk_types.tool_result -> string

val merge_env : (string * string) list -> string array

type server_spec =
  { command : string
  ; args : string list
  ; env : (string * string) list
  ; name : string
  }

type transport =
  | Stdio of
      { client : t
      ; spec : server_spec
      }
  | Http of
      { close_fn : unit -> unit
      ; base_url : string
      ; headers : (string * string) list
      }

type managed =
  { tools : Tool.t list
  ; name : string
  ; transport : transport
  }

val connect_and_load
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> server_spec
  -> (managed, Error.sdk_error) result

val connect_all
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> server_spec list
  -> (managed list, Error.sdk_error) result

val reconnect
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> managed
  -> (managed, Error.sdk_error) result

val connect_all_best_effort
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> server_spec list
  -> managed list * (string * Error.sdk_error) list

val close_managed : managed -> unit
val close_all : managed list -> unit
