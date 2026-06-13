(** OTel Dispatch Hook — registers a [Tool_dispatch] observer that
    records each handled tool call as an OpenTelemetry span gated by
    {!Otel_config.enabled}.

    Span attributes use OpenTelemetry GenAI + MCP semantic-convention keys
    ([gen_ai.tool.name], [gen_ai.operation.name], [mcp.method.name]) so Datadog
    v1.37+/Grafana auto-categorise these spans as AI/LLM activity while still
    seeing the underlying MCP [tools/call] method. Payload-level MCP tool
    failures use [error.type=tool_error]; the MASC failure taxonomy is kept in
    [masc.mcp.tool.failure_class].

    Internal helper [on_tool_result] is intentionally hidden — the
    hook is registered through {!install} once at startup, after
    which dispatch invokes it implicitly.

    @since 2.103.0 *)

type transport_context =
  { network_protocol_name : string option
  ; network_protocol_version : string option
  ; network_transport : string option
  }
(** Request-local MCP transport metadata for the OTel MCP semantic convention
    [network.*] attributes. *)

type request_context =
  { jsonrpc_request_id : string option
  ; mcp_session_id : string option
  ; mcp_protocol_version : string option
  ; transport : transport_context option
  }
(** Request-local MCP context available while handling a JSON-RPC
    [tools/call] request. Fields are optional because internal dispatches,
    notifications, and non-network transports do not always have a request
    id/session/protocol version or transport metadata. *)

val http_transport_context : protocol_version:string -> transport_context
(** Standard MCP-over-HTTP transport context for HTTP/1.1 or HTTP/2. The
    protocol version is the network protocol version, e.g. ["1.1"] or ["2"]. *)

val with_request_context : request_context -> (unit -> 'a) -> 'a
(** Bind MCP request context for spans emitted by dispatch observers inside
    [f]. Outside an Eio fiber this degrades to [f ()], so non-Eio unit tests
    and pre-bootstrap callers do not crash. *)

val current_request_context : unit -> request_context option
(** Return the request-local MCP context currently bound to this Eio fiber, if
    any. Used by non-span telemetry surfaces that need to share the same MCP
    semantic-convention attributes as the dispatch hook. *)

val with_test_span_emitter :
  enabled:bool ->
  emit_span:
    (name:string ->
     attrs:Opentelemetry.key_value list ->
     kind:Opentelemetry.Span_kind.t ->
     status:Opentelemetry.Span_status.t option ->
     unit) ->
  (unit -> 'a) ->
  'a
(** Temporarily override OTel enablement and span emission for focused
    observer tests. Restores the previous emitter after [f] returns/raises. *)

val install : unit -> unit
(** Register {!on_tool_result} as a [Tool_dispatch] observer.
    Idempotent at the call site (calling twice would register the
    callback twice — server bootstrap calls it exactly once). *)
