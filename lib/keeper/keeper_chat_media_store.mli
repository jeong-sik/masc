(** Keeper_chat_media_store — content-addressed store for model-generated media.

    RFC-0301: OAS streams model-generated media as [MediaDelta { media_type; data }];
    the keeper-chat bridge persists it here and surfaces it by URL token instead of
    reducing it to a byte count. Generalizes the voice-clip token/serve pattern
    ([/api/v1/voice/audio/<token>]) to an arbitrary [media_type]. Files live under
    [<masc_dir>/media/] as [<token>.<ext>]; identical media type + payload pairs
    dedup to one file. Served by [GET /api/v1/media/<token>] behind read auth.
    Retention is enforced opportunistically on persist via generated-media age and
    directory-size caps. *)

type persist_error =
  | Unsupported_source_type of Agent_sdk.Types.media_source_kind
  | Invalid_base64 of string
  | Media_too_large of { size_bytes : int; max_bytes : int }
  | Write_failed of string

(** Broad category of a media type, driving the keeper-chat block type used when a
    generated media block is persisted for reload (RFC-0301 item 6). *)
type media_category =
  | Image
  | Audio
  | Document
  | Other

(** [media_type] (IANA type from the OAS media block) -> file extension; unknown
    types fall back to ["bin"]. *)
val ext_of_media_type : string -> string

(** [media_type] -> broad {!media_category}; unknown types are [Other]. Single SSOT
    with {!ext_of_media_type} / {!content_type_of_ext}. *)
val category_of_media_type : string -> media_category

(** File extension (no leading dot) -> HTTP content-type; unknown ->
    ["application/octet-stream"]. *)
val content_type_of_ext : string -> string

(** Content-type for an on-disk media file, derived from its extension. Used by
    the serve route. *)
val content_type_of_path : string -> string

(** [true] iff [token] is a well-formed store token (64-char lowercase hex).
    Guards the serve route path parameter; the token is not a bearer capability. *)
val valid_token : string -> bool

(** Raw generated-media byte budget used before durable writes. *)
val max_raw_bytes : unit -> int

(** Encoded-carrier budget for live stream accumulation. Gives base64 expansion
    headroom over {!max_raw_bytes}. *)
val max_wire_bytes : unit -> int

(** [file_path_of_token ~base_dir ~token] is the on-disk path of the stored media
    for [token], or [None] if the token is malformed, absent, or reaped. *)
val file_path_of_token : base_dir:string -> token:string -> string option

(** [persist_result ~base_dir ~media_type ~data] writes raw [data] under a
    deterministic token and returns [(token, url)] where [url] is
    [/api/v1/media/<token>]. The write is idempotent and atomic. *)
val persist_result :
  base_dir:string -> media_type:string -> data:string -> (string * string, string) result

(** Raising compatibility wrapper around {!persist_result}. New stream-facing code
    should use the result-returning functions so storage failures stay observable
    without tearing down the stream. *)
val persist : base_dir:string -> media_type:string -> data:string -> string * string

(** Human-readable error for logs and protocol-error events. Does not include the
    media payload. *)
val persist_error_to_string : persist_error -> string

(** [persist_media_source_result] decodes the OAS media source carrier first.
    [Base64] is decoded to raw bytes before persisting; [Url] and [File_id] are
    rejected until this store has an explicit fetch/resolve implementation. *)
val persist_media_source_result :
  base_dir:string ->
  media_type:string ->
  source_type:Agent_sdk.Types.media_source_kind ->
  data:string ->
  (string * string, persist_error) result
