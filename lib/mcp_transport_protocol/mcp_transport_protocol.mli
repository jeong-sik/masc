(** MCP Protocol Utilities — JSON-RPC types, protocol-version negotiation,
    and HTTP content negotiation for the Streamable HTTP transport.

    This module is the SSOT for {b JSON-RPC core} (request/response types,
    builders, validators), {b protocol version} (supported set, validation,
    normalization), and {b HTTP negotiation} (delegates parsing to
    {!Mcp_protocol.Http_negotiation} from the SDK; layers MASC's
    [accept_mode] with [Legacy_accepted] for backward compatibility). *)

(** {1 JSON-RPC Core Types} *)

type jsonrpc_request = {
  jsonrpc : string;
  id : Yojson.Safe.t option; [@default None]
  method_ : string;
  params : Yojson.Safe.t option; [@default None]
} [@@deriving yojson { strict = false }]
(** JSON-RPC 2.0 request. [id = None] denotes a notification. The
    [method_] OCaml field maps to the JSON ["method"] key. *)

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
(** Per the JSON-RPC 2.0 spec, valid ids are [`Null], [`String _],
    [`Int _], [`Intlit _], or [`Float _]. *)

val validate_initialize_params : Yojson.Safe.t option -> (unit, string) result
(** Checks that [params] for the MCP [initialize] method contain
    [protocolVersion : string], [clientInfo : { name; version }], and
    [capabilities] objects. Returns a human-readable error string on
    missing or wrong-typed fields. *)

(** {1 JSON-RPC Response Builders} *)

val make_response : id:Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** [make_response ~id result] builds [{jsonrpc:"2.0", id, result}]. *)

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

      [Legacy_accepted] — Accept header lacks one of those, but the
      [allow_legacy] flag (gated on the [MASC_ALLOW_LEGACY_ACCEPT] env)
      lets the request through for backward compatibility.

      [Rejected] — neither mode applies. *)
  type accept_mode =
    | Streamable
    | Legacy_accepted
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

  val accepts_streamable_mcp : string option -> bool
  (** [true] iff the header advertises both JSON and SSE
      (the Streamable HTTP transport requirement). *)

  val classify_mcp_accept :
    allow_legacy:bool -> string option -> accept_mode
  (** Top-level classification: [Streamable] if both media types are
      advertised, else [Legacy_accepted] when [allow_legacy = true],
      else [Rejected]. *)
end

(** {1 Protocol Version} *)

val supported_protocol_versions : string list
(** Versions accepted by this server (delegates to
    {!Mcp_protocol.Version.supported_versions}). *)

val default_protocol_version : string
(** Latest version (delegates to {!Mcp_protocol.Version.latest}). *)

val is_supported_protocol_version : string -> bool
(** Membership test against {!supported_protocol_versions}. *)

val validate_protocol_version : string -> (string, string) result
(** [Ok v] if supported, otherwise [Error msg] listing the supported set. *)

val normalize_protocol_version : string -> string
(** Returns the input if supported, else {!default_protocol_version}. *)

val protocol_version_from_params : Yojson.Safe.t option -> string
(** Extract [protocolVersion] from a JSON-RPC [params] object,
    falling back to {!default_protocol_version}. *)

val protocol_version_from_initialize_request_json :
  Yojson.Safe.t -> string option
(** Returns [Some v] if [json] is a well-formed [initialize] request,
    where [v] is normalized to a supported version. Returns [None] for
    any other shape. *)

val protocol_version_from_body : string -> string option
(** Convenience: parses [body_str] as JSON then delegates to
    {!protocol_version_from_initialize_request_json}. Returns [None] on
    malformed JSON. *)
