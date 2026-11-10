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

val json_schema_type_to_param_type : string -> Types.param_type
val json_schema_type_to_param_type_result : string -> (Types.param_type, string) result
val json_schema_to_params : Yojson.Safe.t -> Types.tool_param list
val json_schema_to_params_result : Yojson.Safe.t -> (Types.tool_param list, string) result
val mcp_tool_of_agent_core_tool : Mcp_schema.Sdk_types.tool -> mcp_tool

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

val mcp_tool_of_json : Yojson.Safe.t -> mcp_tool option

(** {1 Client handle} *)

type t

(** Optional host-owned model access. The subprocess sends standard MCP
    sampling requests; the host chooses credentials and model policy.
    Ordinary callback exceptions become protocol errors so the connection can
    serve subsequent requests. Eio cancellation propagates to the caller.

    A reply frame larger than the connection's byte limit is replaced by the
    transport with a short JSON-RPC error. *)
type sampling_handler = Mcp_protocol.Sampling.create_message_params ->
  (Mcp_protocol.Sampling.create_message_result, string) result

(** {1 Connection lifecycle} *)

val connect
  :  sw:Eio.Switch.t
  -> mgr:_ Eio.Process.mgr
  -> command:string
  -> args:string list
  -> ?env:string array
  -> ?cwd:Eio.Fs.dir_ty Eio.Path.t
  -> ?max_response_bytes:int
  -> ?stderr:Eio.Flow.sink_ty Eio.Resource.t
  -> ?sampling_handler:sampling_handler
  -> unit
  -> (t, Error.t) result

val initialize : t -> client_version:string -> (unit, Error.t) result
(** Send [initialize]. [client_version] is the version of the build that runs
    this client; the server reads it in [clientInfo]. *)

val request_stop : t -> unit
(** Best-effort TERM through this connection's owned process handle. Does not
    wait for transport shutdown or prove child/group exit. *)
val close : t -> unit
val process_id : t -> int
(** The exact child started by [connect]. The number is for observation and
    retained identity, never authority to signal a later process with that PID. *)
val await_exit : t -> Eio.Process.exit_status
(** Await the owned process handle; does not close the connection or impose a
    timeout. The process manager defines descendant cleanup. *)

(** {1 Tool operations} *)

(** Unabridged SDK values, including outputSchema and structuredContent.
    [list_tools_full] reads one page; it does not accumulate unbounded pages
    from an optional server.
    [call_tool_full] preserves [is_error]; callers must inspect it.
    A connection's optional [max_response_bytes] is enforced by the NDJSON
    reader before allocating/parsing a complete server message. The same limit
    applies to complete outgoing Response/Error envelopes, including sampling
    reply IDs. Outgoing requests and notifications are not response-limited.
    Oversized responses use a neutral bounded error; if its ID alone prevents
    that error from fitting, the transport closes without writing it. *)
val list_tools_full : t -> (Mcp_schema.Sdk_types.tool list, Error.t) result
val call_tool_full :
  t -> name:string -> arguments:Yojson.Safe.t ->
  (Mcp_schema.Sdk_types.tool_result, Error.t) result

(** {1 Tool results} *)
val text_of_tool_result : Mcp_schema.Sdk_types.tool_result -> string
