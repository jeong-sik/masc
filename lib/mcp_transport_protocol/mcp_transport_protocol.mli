(** MCP Protocol Utilities — JSON-RPC types, protocol-version negotiation,
    and HTTP content negotiation for the Streamable HTTP transport.

    This module is the SSOT for {b JSON-RPC core} (request/response types,
    builders, validators), {b protocol version} (supported set, validation,
    normalization), and {b HTTP negotiation} (delegates parsing to
    {!Mcp_protocol.Http_negotiation} from the SDK; layers MASC's
    Streamable HTTP Accept classification). *)

(** {1 JSON-RPC Core Types} *)

type jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option; [@default None]
  method_ : string;
  params : Yojson.Safe.t option; [@default None]
} [@@deriving yojson { strict = false }]
(** JSON-RPC 2.0 request. [id = None] denotes a notification. The
    [method_] OCaml field maps to the JSON ["method"] key. *)

type request_id
(** Exact MCP request identity. Integer ids retain their canonical JSON
    lexeme so callers never round-trip through a binary float. *)

type request_id_error =
  | Null_request_id
  | Non_lossless_number
  | Invalid_integer_lexeme of string
  | Invalid_request_id_kind

val request_id_of_yojson :
  Yojson.Safe.t -> (request_id, request_id_error) result
(** Parses the MCP request-id contract: string or integer only. [`Float _]
    is rejected even when mathematically integral because Yojson has already
    discarded the producer's exact decimal lexeme. *)

val request_id_to_yojson : request_id -> Yojson.Safe.t
(** Lossless wire projection of a typed request id. *)

val request_id_equal : request_id -> request_id -> bool

val request_id_error_to_string : request_id_error -> string

val has_field : string -> Yojson.Safe.t -> bool
(** [has_field key json] is [true] when [json] is an [`Assoc] containing [key]. *)

val get_field : string -> Yojson.Safe.t -> Yojson.Safe.t option
(** [get_field key json] returns [Some v] when [json] is an [`Assoc] mapping
    [key] to [v], else [None]. *)

val is_jsonrpc_v2 : Yojson.Safe.t -> bool
(** Returns [true] iff [json] has a top-level field [jsonrpc = "2.0"]. *)

val is_jsonrpc_response : Yojson.Safe.t -> bool
(** Recognizes an [`Assoc] with [jsonrpc = "2.0"], an [id], either
    [result] or [error], and no [method] — i.e. a JSON-RPC response. *)

val is_notification : jsonrpc_request -> bool
(** A request is a notification iff its [id] is [None]. *)

val get_id : jsonrpc_request -> Yojson.Safe.t
(** Returns the request id, defaulting to [`Null] for notifications. *)

val is_valid_request_id : Yojson.Safe.t -> bool
(** MCP requests admit string or integer ids. Null and floating-point ids are
    rejected, as required by the MCP request contract. *)

val validate_initialize_params : Yojson.Safe.t option -> (unit, string) result
(** Checks that [params] for the MCP [initialize] method contain
    [protocolVersion : string], [clientInfo : { name; version }], and
    [capabilities] objects. Returns a human-readable error string on
    missing or wrong-typed fields. *)

(** {1 subscriptions/listen (2026-07-28)} *)

type subscription_filter =
  { tools_list_changed : bool
  ; prompts_list_changed : bool
  ; resources_list_changed : bool
  ; resource_subscriptions : string list
  }
(** The notification types one [subscriptions/listen] request asked for. A
    record of the four the specification defines rather than a list of strings:
    an unrecognised key in the request cannot become a subscription, and a type
    added later is a compile error at every match instead of a silent no-op.

    The server {b MUST NOT} send a type the client did not request. *)

val empty_subscription_filter : subscription_filter
(** Subscribed to nothing. What an absent [notifications] object means. *)

val subscription_filter_of_params : Yojson.Safe.t option -> subscription_filter
(** Reads [params.notifications]. Every field is optional and omitting one is
    "equivalent to not subscribing to that notification type", so a missing
    object is {!empty_subscription_filter} rather than an error. *)

val subscription_filter_to_json : subscription_filter -> Yojson.Safe.t
(** The subset the server agreed to honour, for the acknowledgement. A type
    that was not asked for is {b absent} rather than [false], matching "types
    the server does not support are omitted". *)

val subscription_id_meta_key : string
(** ["io.modelcontextprotocol/subscriptionId"] — the [_meta] key every message
    on a subscription stream carries, whose value is the JSON-RPC id of the
    [subscriptions/listen] request that opened it. *)

val tag_notification_with_subscription :
  subscription_id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** Adds {!subscription_id_meta_key} to a notification's [params._meta],
    creating [params] or [_meta] if absent and leaving an id already present
    alone. On stdio one channel carries every subscription, so a client
    {b MUST} use this field to demultiplex. *)

(** {1 JSON-RPC Response Builders} *)

val server_info_meta_key : string
(** ["io.modelcontextprotocol/serverInfo"] — the reserved [_meta] key a server
    identifies itself under on every result (2026-07-28 basic/index,
    per-response protocol fields). *)

val server_info_meta_value : Yojson.Safe.t
(** This server's [Implementation]: name, title, and version, the last from
    {!Build_version}. Sole owner of those three — {!Mcp_server.server_info}
    extends this rather than restating them, so the handshake identity and the
    per-result identity cannot drift.

    Self-reported and unverified by the protocol: the spec has it used for
    display, logging, and debugging, never for a behavioural or security
    decision. *)

val make_response : id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** [make_response ~id result] builds [{jsonrpc:"2.0", id, result}].

    When [result] is an object without a [resultType] member, ["complete"]
    is inserted (SEP-2322, protocol revision 2026-07-28).  A [result] that
    already carries [resultType] is passed through unchanged, so a handler
    can answer ["input_required"] for a Multi Round-Trip turn. *)

val make_error :
  ?data:Yojson.Safe.t ->
  id:Yojson.Safe.t ->
  int ->
  string ->
  Yojson.Safe.t
(** [make_error ?data ~id code message] builds the JSON-RPC error
    envelope. [data] is appended to the [error] object when provided. *)

val jsonrpc_notification : ?params:Yojson.Safe.t -> string -> Yojson.Safe.t
(** [jsonrpc_notification ?params method_name] builds an id-less
    [{jsonrpc:"2.0", method, params?}] notification. *)

(** {1 HTTP Content Negotiation} *)

module Http_negotiation : sig
  (** MASC-specific accept classification.

      [Streamable] — Accept header advertises both [application/json] and
      [text/event-stream] (the spec-compliant mode).

      [Rejected] — neither mode applies. *)
  type accept_mode =
    | Streamable
    | Rejected

  val sse_content_type : string
  (** Re-export of {!Mcp_protocol.Http_negotiation.sse_content_type}. *)

  val json_content_type : string
  (** Re-export of {!Mcp_protocol.Http_negotiation.json_content_type}. *)

  val accepts_sse_header : string option -> bool
  (** [true] iff the header advertises [text/event-stream]. *)

  val accepts_json : string option -> bool
  (** [true] iff the header advertises [application/json] or [*\/*]. *)

  val is_json_content_type : string option -> bool
  (** [true] iff the Content-Type value is exactly [application/json],
      allowing media-type parameters such as [charset]. Wildcards and
      comma-separated Accept-style lists are rejected. *)

  val accepts_streamable_mcp : string option -> bool
  (** [true] iff the header advertises both JSON and SSE
      (the Streamable HTTP transport requirement). *)

  val classify_mcp_accept : string option -> accept_mode
  (** Top-level classification: [Streamable] if both media types are
      advertised, else [Rejected]. *)
end

(** {1 Protocol Version} *)

val supported_protocol_versions : string list
(** Versions accepted by this server (delegates to
    {!Mcp_protocol.Version.supported_versions}, with the 2026-07-28
    stateless revision overlaid while the vendored SDK catches up). *)

val default_protocol_version : string
(** Latest version (delegates to {!Mcp_protocol.Version.latest}). *)

val is_supported_protocol_version : string -> bool
(** Membership test against {!supported_protocol_versions}. *)

val is_stateless_protocol_version : string -> bool
(** [true] for protocol revisions that do not use the initialize
    handshake or [Mcp-Session-Id] as protocol state. Accepts both
    the release-candidate date label and the current draft alias. *)

val validate_protocol_version : string -> (string, string) result
(** [Ok v] if supported, otherwise [Error msg] listing the supported set. *)

val normalize_protocol_version : string -> string
(** Returns the input if supported, else {!default_protocol_version}. *)

val protocol_version_from_params : Yojson.Safe.t option -> string
(** Extract [protocolVersion] from a JSON-RPC [params] object,
    falling back to {!default_protocol_version}. *)

val client_capabilities_meta_key : string
(** ["io.modelcontextprotocol/clientCapabilities"] — the second [_meta] field
    2026-07-28 marks required on every client request. A request missing a
    required field is malformed and answered with [-32602]. *)

val request_meta_has_key : string -> string -> bool
(** [request_meta_has_key body_str key] is whether [params._meta] in [body_str]
    carries [key] with a non-null value. An unparseable body, an absent
    [_meta], and an explicit [null] all answer [false] — none of them is a
    declaration. *)

val protocol_version_meta_key : string
(** Fully qualified per-request [_meta] key used by the 2026-07-28
    stateless protocol: ["io.modelcontextprotocol/protocolVersion"]. *)

val protocol_version_from_request_meta_json : Yojson.Safe.t -> string option
(** Extract the per-request protocol version from
    [params._meta.io.modelcontextprotocol/protocolVersion]. Returns
    [None] for legacy initialize-only messages or malformed shapes. *)

val protocol_version_from_request_meta_body : string -> string option
(** Parses a JSON-RPC body and delegates to
    {!protocol_version_from_request_meta_json}. Returns [None] on
    malformed JSON. *)

val body_uses_stateless_protocol : string -> bool
(** [true] iff the JSON-RPC body declares a stateless protocol version
    in per-request [_meta]. *)

val protocol_version_from_body : string -> string option
(** Convenience: parses [body_str] as JSON then delegates to
    {!protocol_version_from_initialize_request_json}. Returns [None] on
    malformed JSON. *)
