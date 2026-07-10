(** MCP Protocol Server Implementation - Eio Native

    Direct-style async MCP server using OCaml 5.x Effect Handlers.
    Provides same functionality as Mcp_server but Eio-native.

    Key differences from legacy version:
    - Direct-style async (no monads, no let-star)
    - Eio.Switch for structured concurrency
    - Eio.Buf_write for buffered I/O
    - Eio.Process for subprocess execution

    Implementation notes:
    - Core request handling is Eio-native
    - Tool implementations are direct-style Eio
*)


(** {1 Types} *)

(** Server state - same as Mcp_server.server_state for compatibility *)
type server_state = Mcp_server.server_state

(** JSON-RPC request (re-exported for convenience) *)
type jsonrpc_request = Mcp_server.jsonrpc_request

(** Tool exposure profile for streamable HTTP endpoints. *)
type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

(** {1 JSON-RPC Helpers (re-exported)} *)

val is_jsonrpc_response : Yojson.Safe.t -> bool
val get_id : jsonrpc_request -> Yojson.Safe.t
val is_valid_request_id : Yojson.Safe.t -> bool
val validate_initialize_params : Yojson.Safe.t option -> (unit, string) result

(** JSON helper: field existence check (re-exported) *)
val has_field : string -> Yojson.Safe.t -> bool

(** JSON helper: get field as Yojson (re-exported) *)
val get_field : string -> Yojson.Safe.t -> Yojson.Safe.t option

(** {1 Network Context} *)

(** Type alias for Eio network capability (Generic + Unix for Agent SDK) *)
type eio_net = [`Generic | `Unix] Eio.Net.ty Eio.Resource.t

(** Set the Eio network reference for server-side network calls.
    Must be called from main_eio.ml during server initialization.
    Requires Generic + Unix capabilities for Agent SDK compatibility.
    @param net Eio network capability *)
val set_net : [> `Generic | `Unix] Eio.Net.ty Eio.Resource.t -> unit

(** Set the Eio clock reference for async sleep. *)
val set_clock : float Eio.Time.clock_ty Eio.Resource.t -> unit

(** Get the Eio clock reference optionally. *)
val get_clock_opt : unit -> float Eio.Time.clock_ty Eio.Resource.t option

(** Get the Eio clock reference. Returns Error if not set. *)
val get_clock : unit -> (float Eio.Time.clock_ty Eio.Resource.t, string) result

(** {1 State Management} *)

(** Create server state (synchronous, no effect)
    @param test_mode When [true], disable workspace authentication so
    unit tests can exercise handlers without provisioning credentials.
    Production callers must leave this unset.
    @param base_path Workspace/base path; MASC data lives under [<base_path>/.masc]. *)
val create_state : ?test_mode:bool -> base_path:string -> unit -> server_state

(** Create server state with Eio context.

    @param sw Eio.Switch for structured concurrency
    @param proc_mgr Eio process manager for agent spawning
    @param fs Eio filesystem for file operations
    @param clock Eio time clock for timestamps/sleep
    @param mono_clock Eio monotonic clock
    @param net Eio network capability for HTTP/TLS calls
    @param base_path Workspace/base path; MASC data lives under [<base_path>/.masc]. *)
val create_state_eio :
  ?mcp_http_transport:Server_mcp_transport_http_sse_owner.t ->
  sw:Eio.Switch.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  net:[> `Generic | `Unix] Eio.Net.ty Eio.Resource.t ->
  base_path:string ->
  server_state

(** {1 Request Handling - Eio Native} *)

(** Handle incoming JSON-RPC request string (Eio direct-style)

    This is the main entry point for Eio-native request handling.
    Uses execute_tool_eio for tool calls.

    @param clock Eio time clock for Session_eio timeout operations
    @param sw Eio.Switch for structured concurrency
    @param mcp_session_id Optional HTTP MCP session ID for identity continuity
    @param state Server state
    @param request_str Raw JSON-RPC request string
    @return JSON response *)
val handle_request :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  sw:Eio.Switch.t ->
  ?profile:tool_profile ->
  ?mcp_session_id:string ->
  ?otel_mcp_protocol_version:string ->
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  ?auth_token:string ->
  ?internal_keeper_runtime:bool ->
  server_state ->
  string ->
  Yojson.Safe.t

(** Execute a single tool by name (for REST API).
    Returns a structured {!Tool_result.result} carrying success flag,
    typed payload, tool name, timing, and failure classification. *)
val execute_tool_eio :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?profile:tool_profile ->
  ?mcp_session_id:string ->
  ?auth_token:string ->
  ?internal_keeper_runtime:bool ->
  server_state ->
  name:string ->
  arguments:Yojson.Safe.t ->
  Tool_result.result

(** Clear MCP resource subscriptions associated with a session.
    Called by streamable HTTP transport when a session is deleted. *)
val clear_resource_subscriptions_for_session : string -> unit

(** {1 Stdio Transport - Eio Native} *)

(** Run MCP server in stdio mode with Eio

    Reads JSON-RPC requests from stdin, writes responses to stdout.
    Uses length-prefixed framing (Content-Length header).

    @param sw Eio.Switch for structured concurrency
    @param env Eio environment (for stdin/stdout)
    @param state Server state *)
val run_stdio : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> server_state -> unit

(** {1 Governance} *)

(** Governance configuration *)
type governance_config = {
  level: string;
  audit_enabled: bool;
  anomaly_detection: bool;
}

(** Get default governance config for a given level.
    - "development" (default): audit=false, anomaly=false
    - "production": audit=true, anomaly=false
    - "enterprise"/"paranoid": audit=true, anomaly=true *)
val governance_defaults : string -> governance_config

(** {1 MCP Sessions} *)

(** MCP session record for HTTP session persistence *)
type mcp_session_record = {
  id: string;
  agent_name: string option;
  created_at: float;
  last_seen: float;
}

(** Serialize MCP session to JSON *)
val mcp_session_to_json : mcp_session_record -> Yojson.Safe.t

(** Deserialize MCP session from JSON *)
val mcp_session_of_json : Yojson.Safe.t -> mcp_session_record option
