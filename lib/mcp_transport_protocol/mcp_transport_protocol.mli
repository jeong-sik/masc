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

(** {1 JSON-RPC Response Builders} *)

val make_response : id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** [make_response ~id result] builds [{jsonrpc:"2.0", id, result}]. *)

val make_complete_response : id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** Builds a successful current-protocol response and injects
    [resultType = "complete"]. The result must be a JSON object. *)

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

  val exists_accepted :
    string ->
    check:(type_:string -> subtype:string -> bool) ->
    bool
  (** [exists_accepted h ~check] parses [h] (Accept header) via the SDK
      and returns [true] iff some entry has positive quality and
      satisfies [check]. [type_] and [subtype] are passed lowercased. *)

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
(** The single current protocol revision accepted by this server. *)

val default_protocol_version : string
(** The current protocol revision, ["2026-07-28"]. *)

val is_supported_protocol_version : string -> bool
(** Membership test against {!supported_protocol_versions}. *)

val is_stateless_protocol_version : string -> bool
(** [true] exactly for the supported current revision. *)

val validate_protocol_version : string -> (string, string) result
(** [Ok v] if supported, otherwise [Error msg] listing the supported set. *)

val protocol_version_meta_key : string
(** Fully qualified per-request [_meta] key used by the 2026-07-28
    stateless protocol: ["io.modelcontextprotocol/protocolVersion"]. *)

val protocol_version_from_request_meta_json : Yojson.Safe.t -> string option
(** Extract the per-request protocol version from
    [params._meta.io.modelcontextprotocol/protocolVersion]. Returns
    [None] for malformed shapes. *)

val protocol_version_from_request_meta_body : string -> string option
(** Parses a JSON-RPC body and delegates to
    {!protocol_version_from_request_meta_json}. Returns [None] on
    malformed JSON. *)
