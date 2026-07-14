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
      friends are kept optional for explicit pure test/replay
      construction through {!For_testing.create_state}.
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

type publication_recovery_activation_row =
  | Publication_recovery_owner_pending of { owner : string }
  | Publication_recovery_owner_running of { owner : string }
  | Publication_recovery_owner_report of
      Fs_compat.publication_recovery_reconciliation_report
  | Publication_recovery_owner_identity_rejected of
      { owner : string
      ; error : string
      }
  | Publication_recovery_owner_reconciliation_failed of
      { owner : string
      ; error : Fs_compat.publication_recovery_reconciliation_error
      }
  | Publication_recovery_owner_reconciliation_crashed of
      { owner : string
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Publication_recovery_owner_cancelled of
      { owner : string
      ; reason : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Publication_recovery_owner_inventory_issue of
      Fs_compat.publication_recovery_owner_inventory_row

type publication_recovery_activation_report

type publication_recovery_runtime

type workspace_scope =
  { config : Workspace.config
  ; publication_recovery : publication_recovery_runtime option
  }
(** One immutable snapshot of the active workspace, exact recovery registry,
    and its retained activation report. [None] exists only in
    {!For_testing.create_state}. *)

type workspace_runtime

type server_state = private {
  workspace_runtime : workspace_runtime;
  session_registry : Session.registry;
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
    The opaque [workspace_runtime] owns the one atomic scope and the
    process-fixed MASC root, so callers can observe snapshots but cannot
    mutate the cell directly. Eio handles are [option] because
    {!For_testing.create_state} supports pure replay and test harnesses without
    an active switch. *)

val workspace_scope : server_state -> workspace_scope
(** Current immutable workspace runtime snapshot. *)

val workspace_config : server_state -> Workspace.config
(** Current workspace configuration. *)

val workspace_scope_publication_recovery_registry :
  workspace_scope -> Fs_compat.publication_recovery_registry option

val workspace_scope_publication_recovery_report :
  workspace_scope -> publication_recovery_activation_report option

val publication_recovery_activation_report_rows :
  publication_recovery_activation_report ->
  publication_recovery_activation_row list
(** Immutable snapshot of every activation slot at the instant of the call. *)

val publication_recovery_activation_report_to_health_yojson :
  publication_recovery_activation_report -> Yojson.Safe.t
(** Public-health projection. It exposes only typed aggregate counts and
    status categories; owner identities, filesystem paths, exceptions,
    backtraces, and nested reconciliation evidence remain internal. *)

type workspace_switch_error =
  | Workspace_masc_root_mismatch of
      { runtime_root : string
      ; requested_root : string
      }

val workspace_switch_error_to_string : workspace_switch_error -> string

type publication_recovery_activation_error =
  | Publication_recovery_registry_unavailable of
      Fs_compat.publication_recovery_registry_error
  | Publication_recovery_inventory_unavailable of
      Fs_compat.publication_recovery_owner_inventory_error
  | Publication_recovery_owner_activation_rejection_failed of
      { owner : Fs_compat.publication_recovery_owner
      ; keeper_identity_error : string
      ; rejection_error :
          Fs_compat.publication_recovery_activation_rejection_error
      }

val publication_recovery_activation_error_to_string :
  publication_recovery_activation_error -> string

val validate_workspace_config :
  server_state -> Workspace.config -> (unit, workspace_switch_error) result
(** Pure process-root validation shared by workspace preparation and
    {!set_workspace_config}. *)

val set_workspace_config :
  server_state -> Workspace.config -> (unit, workspace_switch_error) result
(** Atomically replace only the active workspace projection. The requested
    {!Workspace.masc_root_dir} must exactly equal the process-fixed runtime
    root; a mismatch is typed and leaves the previous scope unchanged. This
    function performs no filesystem I/O. *)

module For_testing : sig
  val create_state : base_path:string -> server_state
  (** Non-runtime state. Every Eio handle and the publication registry are
      [None]. This constructor is isolated from the production bootstrap
      surface. *)

  val await_publication_recovery_activation :
    publication_recovery_activation_report ->
    publication_recovery_activation_row list
  (** Await every exact slot-completion promise without timeout, polling, or a
      retry budget, then return one immutable row snapshot. Cancellation of
      the calling fiber propagates. *)
end

exception Publication_recovery_activation_failed of
  publication_recovery_activation_error

val create_state_eio :
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
    Subscriptions notification harness. Publication recovery opens and
    inventories one process-lifetime registry synchronously, then reconciles
    each valid owner in an independent child fiber. *)

(** {1 SSE broadcast} *)

val set_sse_callback :
  server_state -> (Yojson.Safe.t -> unit) -> unit
(** Pins the SSE push callback (atomic, so cross-fiber
    visibility is safe). *)

val sse_broadcast : server_state -> Yojson.Safe.t -> unit
(** Pushes [notification] to every connected SSE client
    via {!set_sse_callback}'s installed callback.  No-op
    when no callback is installed. *)
