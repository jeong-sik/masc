(** Complete returned SDK values and original-bound reply references. This
    module performs no storage, lookup, interpretation, dispatch or approval. *)

type t

val mime_type : string
(** Ordinary [application/json]. The reply blob is opaque to artifact/media
    traversal, including arbitrary reference-shaped structured content. *)

val capture_sdk_reply :
  Agent_core_protocol.Mcp_schema.Sdk_types.tool_result -> (t, string) result
(** Serialize the actual returned SDK value with its official serializer, then
    canonicalize the complete JSON. Preserve all represented content, metadata
    and explicit [Some Null] fields. This cannot recover wire fields already
    discarded by the SDK and does not capture a raw JSON-RPC transcript. *)

val reply_json : t -> Yojson.Safe.t
val reply_bytes : t -> string

val restore_reply_bytes : string -> (t, string) result
(** Require exact canonical JSON bytes. Do not decode/re-encode through the
    SDK inverse, which loses explicit null fields. This restores retained JSON,
    without interpreting content or asserting the result succeeded. *)

type link

val link :
  original:Keeper_media_reading_original.t ->
  Tool_output.artifact_ref -> (link, string) result
(** Bind the original request ID, complete body digest and reserved execution
    ID to an official normalized artifact reference. Require [mime_type], a
    positive byte count, empty preview and no answer fingerprint. The caller
    publishes the full blob first; this pure function proves no durability. *)

val artifact : link -> Tool_output.artifact_ref
val link_to_json : link -> Yojson.Safe.t
val link_of_json :
  original:Keeper_media_reading_original.t -> Yojson.Safe.t ->
  (link, string) result
(** Strict original-bound current-schema codec. Reject missing, unknown or
    duplicate fields and malformed or foreign references. Blob availability,
    byte length and content-address checks belong to the storage owner. *)

val validate_progress :
  original:Keeper_media_reading_original.t -> Lane_addon_request_progress.t ->
  (link option, string) result
(** Validate every [Judgment_retained] reply link, including after later phases,
    and return the retained link if present. Judged and commit phases require
    that link. Generic Progress owns transition
    order; the media owner separately validates approval and original ownership.
    A link establishes neither adapter success nor terminal transport receipt. *)
