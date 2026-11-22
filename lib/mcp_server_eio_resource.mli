(** Mcp_server_eio_resource — \`resources/read\` JSON-RPC handler.

    Extracted from {!Mcp_server_eio} as part of the god-file
    decomposition.  Single external entry: {!handle_read_resource_eio}.

    Internal: re-exports of
    \[Mcp_transport_protocol.make_response\] /
    \[Mcp_transport_protocol.make_error\] (used to construct
    JSON-RPC envelopes inside the handler) and
    \[public_tool_help_schemas\] (delegate to {!Config.visible_tool_schemas})
    stay private — none have external callers. *)

type resource_caller =
  | Operator_admin
  | Authenticated_reader of
      { agent_name : string
      ; board_reader : Masc_board_handlers.Board_access.reader
      }
  | Anonymous_reader
(** Authenticated caller identity governing Keeper memory and World Memory
    resource access. Non-admin callers only read their own Keeper memory
    (filtered through current Board readership), cannot read
    [masc://world-memory/log], and receive World Memory claims/facts with
    private sibling-Keeper scopes and cross-Keeper [source_fact_ids] withheld. *)

type resource_target =
  | Tool_help_index
  | Tool_help of string
  | Status_markdown
  | Status_json
  | Tasks_markdown
  | Tasks_json
  | Who_markdown
  | Who_json
  | Messages_markdown
  | Messages_json
  | Events_markdown
  | Events_json
  | Wiki_index_markdown
  | Wiki_index_json
  | Wiki_page_markdown of string
  | Wiki_page_json of string
  | World_memory_claims
  | World_memory_digest
  | World_memory_index
  | World_memory_fact of string
  | World_memory_log
  | Keeper_memory of string
  | Keeper_memory_health of string
  | Unknown of string

val parse_resource_target : string -> resource_target
(** Parse the [resource_id] returned by {!Mcp_server.parse_masc_resource_uri}
    into a closed resource target variant. *)

val world_memory_claims_uri : string
(** Canonical URI for {!World_memory_claims} ([masc://world-memory/claims]). *)

val world_memory_digest_uri : string
(** Canonical URI for {!World_memory_digest} ([masc://world-memory/digest]). *)

val world_memory_index_uri : string
(** Canonical URI for {!World_memory_index} ([masc://world-memory/index]). *)

val world_memory_log_uri : string
(** Canonical URI for {!World_memory_log} ([masc://world-memory/log]).
    Supports optional [?since_seq=<int>&limit=<int>] cursor pagination
    (default limit 100, capped at 500). *)

val register_session_resource_notifier : (uri:string -> unit) -> unit
(** Install the legacy session-scoped [notifications/resources/updated]
    callback from {!Mcp_server_eio_protocol}. *)

val notify_resource_updated : string list -> unit
(** Emit [notifications/resources/updated] for each URI in the list to all
    subscribed 2026-07-28 {!Mcp_subscriptions} streams and any registered
    legacy session subscribers. Must be called from an Eio fiber (or outside Eio
    before {!Eio_guard.enable}), never inside a raw systhread while Eio is
    active. *)

val notify_world_memory_updated : unit -> unit
(** Emit [notifications/resources/updated] on {!world_memory_claims_uri} and
    {!world_memory_log_uri}. *)

val handle_read_resource_eio :
  ?caller:resource_caller ->
  Mcp_server.server_state ->
  Yojson.Safe.t ->
  Yojson.Safe.t option ->
  Yojson.Safe.t
(** [handle_read_resource_eio ?caller state id params] handles a
    [resources/read] JSON-RPC call. Defaults to {!Anonymous_reader} so
    callers that omit identity fail closed on gated Keeper memory targets.

    Parameter contract:
    - [state]: server state (provides config + session registry).
    - [id]: JSON-RPC request id (echoed in response).
    - [params]: optional JSON-RPC params object.  When [None] or
      not [`Assoc _], returns an error envelope with code [-32602]
      (the JSON-RPC 2.0 Invalid params code).

    Required fields in [params]:
    - [uri]: non-empty string.  Empty / missing produces error
      code [-32602] with message [Missing uri].

    The URI is parsed via {!Mcp_server.parse_masc_resource_uri}
    into a (resource_id, uri) pair, and the handler routes to the
    appropriate read source (messages directory, tool-help
    schemas, etc.) based on the resource id.

    Synchronous workspace, event, worktree, and library filesystem reads run
    in a system thread so they cannot block the cooperative Eio domain.
    Session registry reads remain on the calling fiber because they may yield
    through the registry actor. System-thread filesystem exceptions ([Sys_error],
    [Unix.Unix_error]) on World Memory resource reads are converted into
    typed [-32603] Internal_error envelopes while Eio cancellation propagates.

    Returns a JSON-RPC response envelope (jsonrpc / id / result or
    error fields).  Never raises — all error paths produce error
    envelopes via {!Mcp_transport_protocol.make_error}. *)

val wiki_resources : base_path:string -> Mcp_server.mcp_resource list
(** One [masc://wiki/<topic>] resource per page in the wiki, in page-name
    order, and [masc://wiki/log] first when the wiki has a log. A page's title
    and summary become the resource's title and description; a page whose
    header does not read is listed by file name with the reason. An absent
    wiki directory lists nothing.

    The pages are also reachable through the [masc://wiki/{topic}] template,
    which a client that only lists resources cannot expand. The filesystem
    reads run in a system thread. *)

module For_testing : sig
  val blocking_io_execution_context : unit -> Eio_guard.execution_context
  (** Execution context observed inside the resource filesystem boundary. *)

  val filter_ordinary_snapshot_for_reader :
    ?base_path:string ->
    reader:Masc_board_handlers.Board_access.reader ->
    Keeper_memory_os_current.t ->
    Keeper_memory_os_current.t * int
  (** Filter an ordinary Memory OS snapshot for [reader], transitively
      withholding derived facts whose premises are unreadable and scrubbing
      delta fields. Returns the filtered snapshot and withheld fact count. *)
end
