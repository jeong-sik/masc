(** Mcp_server — MCP server runtime: JSON-RPC envelope
    helpers, resource catalogue, runtime state, SSE
    broadcaster.

    Splits into four concerns:
    - {b JSON-RPC plumbing} — re-exported pinned aliases of
      {!Mcp_transport_protocol.jsonrpc_request} and the
      validator / accessor / response-builder helpers so
      callers reach them via [Mcp_server.X] without
      importing the transport module.
    - {b Icon + resource catalogue} — the static
      [resources] / [resource_templates] tables advertised
      to the MCP client during initialisation, plus the
      themed-SVG icon helper.
    - {b Server state} — the runtime record threaded
      through every request handler.  [Eio.Switch.t] and
      friends are kept optional so the legacy non-Eio path
      ({!create_state}) still compiles.
    - {b SSE broadcast} — atomic callback ref consumed by
      the HTTP / SSE transport.

    Internal helpers stay private at this boundary
    ([svg_icon_data_uri], [text_icon] / [json_icon] /
    [doc_icon], [icons_for_mime], [server_icons],
    [make_resource_template] (callers use the static
    {!resource_templates} list, not the constructor),
    [task_fsm_transition_to_json], [supported_protocol_versions],
    [default_protocol_version], [is_supported_protocol_version],
    [validate_protocol_version], [jsonrpc_notification]). *)

(** {1 JSON-RPC envelope (re-exported from Mcp_transport_protocol)} *)

type jsonrpc_request = Mcp_transport_protocol.jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option;
  method_ : string;
  params : Yojson.Safe.t option;
}
(** Type re-export so callers reach it via
    [Mcp_server.jsonrpc_request] with field access
    preserved.  Identity preserved with the source type. *)

val jsonrpc_request_of_yojson :
  Yojson.Safe.t -> (jsonrpc_request, string) result
val jsonrpc_request_to_yojson : jsonrpc_request -> Yojson.Safe.t

val has_field : string -> Yojson.Safe.t -> bool
val get_field : string -> Yojson.Safe.t -> Yojson.Safe.t option

val is_jsonrpc_v2 : Yojson.Safe.t -> bool
val is_jsonrpc_response : Yojson.Safe.t -> bool
val is_notification : jsonrpc_request -> bool

val get_id : jsonrpc_request -> Yojson.Safe.t
val is_valid_request_id : Yojson.Safe.t -> bool

val validate_initialize_params :
  Yojson.Safe.t option -> (unit, string) result
(** Validates an [initialize] params payload.  Returns
    [Ok ()] on a well-formed envelope with a supported
    protocol version, [Error msg] otherwise. *)

val make_response :
  id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
val make_error :
  ?data:Yojson.Safe.t ->
  id:Yojson.Safe.t ->
  int ->
  string ->
  Yojson.Safe.t

val normalize_protocol_version : string -> string
val protocol_version_from_params : Yojson.Safe.t option -> string
val validate_protocol_version : string -> (string, string) result
(** Returns [Ok normalized] when the input matches one of
    the supported protocol versions, [Error msg]
    otherwise.  Pinned because [test/test_mcp_server_eio.ml]
    aliases the module ([module Mcp = Masc.Mcp_server])
    and exercises the validator directly. *)

(** {1 MCP icons} *)

type mcp_icon = {
  src : string;
  mime_type : string option;
  sizes : string list;
}

val icon_to_json : mcp_icon -> Yojson.Safe.t
val themed_icon : label:string -> bg:string -> fg:string -> mcp_icon

(** {1 Server identity + capabilities} *)

val server_info : Yojson.Safe.t
val capabilities : Yojson.Safe.t

(** {1 Resource catalogue} *)

type mcp_resource = {
  uri : string;
  name : string;
  title : string option;
  description : string;
  mime_type : string;
  icons : mcp_icon list;
  annotations : Yojson.Safe.t option;
  size : int option;
}

type mcp_resource_template = {
  uri_template : string;
  name : string;
  title : string option;
  description : string;
  mime_type : string;
  icons : mcp_icon list;
  annotations : Yojson.Safe.t option;
}

val resource_to_json : mcp_resource -> Yojson.Safe.t
val resource_template_to_json : mcp_resource_template -> Yojson.Safe.t

val make_resource :
  ?title:string ->
  ?annotations:Yojson.Safe.t ->
  ?size:int ->
  uri:string ->
  name:string ->
  description:string ->
  mime_type:string ->
  unit ->
  mcp_resource

val resources : mcp_resource list
val resource_templates : mcp_resource_template list

(** {1 Resource URI parsing} *)

val parse_masc_resource_uri : string -> string * Uri.t
(** [parse_masc_resource_uri uri_str] parses a
    [masc://...] URI into [(resource_id, uri)] where
    [resource_id] joins the host + path segments with [/]
    and [uri] is the parsed [Uri.t] for downstream query
    extraction.  Falls through with [(uri_str, uri)] when
    the scheme is not [masc] (caller decides). *)

val int_query_param :
  Uri.t -> string -> default:int -> int
(** Reads an integer query parameter from [uri] with
    [default] fallback when missing or unparseable. *)

(** {1 Event log reader} *)

val read_event_lines :
  Workspace.config -> limit:int -> string list
(** Reads up to [limit] most-recent event lines from the
    activity-events JSONL log under [config].  Lines are
    raw strings — caller decides whether to parse via
    {!Yojson.Safe.from_string} or treat as opaque. *)

(** {1 Task FSM advertisement} *)

val task_fsm_transitions :
  (string * string list * string * string option) list
(** Static catalogue of legal task FSM transitions:
    [(action, valid_from_states, to_state, gate_predicate)].
    Surfaced through the resource template for
    [masc://meta/task-fsm.json]. *)

val schema_json : Yojson.Safe.t
val schema_markdown : string

(** {1 Server state} *)

type server_state = {
  workspace_config : Workspace.config Atomic.t;
  session_registry : Session.registry;
  mcp_http_transport : Server_mcp_transport_http_sse_owner.t option;
  on_sse_broadcast :
    (Yojson.Safe.t -> unit) option Atomic.t;
  sw : Eio.Switch.t option;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  fs : Eio.Fs.dir_ty Eio.Path.t option;
  clock : float Eio.Time.clock_ty Eio.Resource.t option;
  mono_clock : Eio.Time.Mono.ty Eio.Resource.t option;
  net : Eio_context.eio_net option;
}
(** Runtime state threaded through every request handler.
    [workspace_config] is stored in an atomic reference so
    workspace-switch tools can swap backends without tearing reads
    in concurrent request/background fibers.  Eio handles are
    [option] because the legacy non-Eio bootstrap ({!create_state})
    still needs to construct a state without an active switch. *)

val workspace_config : server_state -> Workspace.config
(** Current workspace configuration. *)

val set_workspace_config : server_state -> Workspace.config -> unit
(** Atomically replace the active workspace configuration. A live HTTP MCP
    transport pins its BasePath for the process lifetime; attempting to switch
    that path is rejected explicitly so session persistence cannot cross
    workspace boundaries. *)

val create_state : base_path:string -> server_state
(** Legacy bootstrap.  Every Eio handle is [None]; the
    server runs without proc-mgr / fs / clock / net.
    Used by tools that need a state-shaped value but no
    runtime fibers (test fixtures, replay harnesses). *)

val create_state_eio :
  ?mcp_http_transport:Server_mcp_transport_http_sse_owner.t ->
  sw:Eio.Switch.t ->
  proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t ->
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  net:Eio_context.eio_net ->
  base_path:string ->
  server_state
(** Production bootstrap.  Wires every Eio handle into
    [Some], starts the [Session] actor consumer, starts
    the {!Runtime_observation} actor, and installs the
    Subscriptions notification harness. *)

(** {1 SSE broadcast} *)

val set_sse_callback :
  server_state -> (Yojson.Safe.t -> unit) -> unit
(** Pins the SSE push callback (atomic, so cross-fiber
    visibility is safe). *)

val sse_broadcast : server_state -> Yojson.Safe.t -> unit
(** Pushes [notification] to every connected SSE client
    via {!set_sse_callback}'s installed callback.  No-op
    when no callback is installed. *)
