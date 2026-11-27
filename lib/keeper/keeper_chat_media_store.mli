(** Keeper_chat_media_store — content-addressed workspace media store.

    Stores both user-uploaded workspace raster images ([POST /api/v1/media]) and
    model-generated [AGENT_CORE] media ([MediaDelta]) under
    [<masc_dir>/media/<sha256>.<ext>], addressed by the 64-char lowercase hex
    SHA-256 digest of the raw payload bytes. Served by
    [GET /api/v1/media/<sha256>] behind read auth.

    MIME types are represented as closed sum types ({!raster_mime} and
    {!media_mime}) verified strictly against payload magic bytes. Unknown
    payloads and SVG/XML payloads are rejected with no opaque fallback.
    Retention is owned by reference-aware workspace media GC rather than
    wall-clock deletion on write. *)

(** Directory leaf under [<masc_dir>/] holding content-addressed media files. *)
val media_subdir : string

(** Closed set of raster image MIME types allowed for HTTP uploads and inline
    workspace rendering. [image/svg+xml] is excluded by design. *)
type raster_mime =
  | Image_png
  | Image_jpeg
  | Image_gif
  | Image_webp

(** Closed set of all workspace media MIME types. Non-raster variants are
    persisted only from verified model-generated [AGENT_CORE] media streams. *)
type media_mime =
  | Raster of raster_mime
  | Audio_mpeg
  | Audio_wav
  | Audio_ogg
  | Audio_midi
  | Application_pdf

(** Broad category of a verified {!media_mime}, driving the keeper-chat block
    type used when generated media is persisted for reload. *)
type media_category =
  | Image
  | Audio
  | Midi
  | Document

(** Positive pixel dimensions parsed from a raster image header. *)
type dimensions =
  { width : int
  ; height : int
  }

(** Receipt returned after verifying and storing a raster upload. *)
type stored_media =
  { sha256 : string
  ; path : string
  ; mime : raster_mime
  ; bytes : int
  ; dimensions : dimensions option
  }

(** Typed refusal reasons for [POST /api/v1/media] raster uploads. *)
type upload_error =
  | Upload_empty
  | Upload_too_large of
      { size_bytes : int
      ; max_bytes : int
      }
  | Upload_svg_not_allowed
  | Upload_unsupported_media_type of
      { declared : string option
      ; sniffed : raster_mime option
      }
  | Upload_mime_mismatch of
      { declared : raster_mime
      ; sniffed : raster_mime
      }
  | Upload_write_failed of string

(** Typed refusal reasons for model-generated [AGENT_CORE] media persistence. *)
type persist_error =
  | Unsupported_source_type of Agent_core.Types.media_source_kind
  | Invalid_base64 of string
  | Media_too_large of
      { size_bytes : int
      ; max_bytes : int
      }
  | Svg_not_allowed
  | Unsupported_media_type of
      { declared : string
      ; sniffed : media_mime option
      }
  | Mime_mismatch of
      { declared : media_mime
      ; sniffed : media_mime
      }
  | Write_failed of string

val all_raster_mimes : raster_mime list
val all_media_mimes : media_mime list

val raster_mime_to_string : raster_mime -> string
val media_mime_to_string : media_mime -> string

(** Strict parsers for MIME strings (parameters after [;] are stripped).
    Unknown values return [None]. *)
val raster_mime_of_string : string -> raster_mime option
val media_mime_of_string : string -> media_mime option

val ext_of_raster_mime : raster_mime -> string
val ext_of_media_mime : media_mime -> string

(** Strict file-extension (no leading dot) to {!media_mime} parser. *)
val media_mime_of_ext : string -> media_mime option

(** Strict on-disk file path extension to {!media_mime} parser. *)
val media_mime_of_path : string -> media_mime option

val category_of_media_mime : media_mime -> media_category
val category_of_media_type : string -> media_category option

(** [true] iff the HTTP Content-Type essence is [image/svg+xml]. *)
val is_svg_content_type : string -> bool

(** [true] when raw bytes begin with an XML/SVG declaration or [<svg] root
    (after optional UTF-8 BOM, whitespace, or leading XML comments). *)
val looks_like_svg_or_xml : string -> bool

(** Sniff raster format strictly from payload magic bytes. *)
val sniff_raster_mime : string -> raster_mime option

(** Sniff any supported workspace media format strictly from payload magic bytes. *)
val sniff_media_mime : string -> media_mime option

(** Parse positive pixel dimensions from a raster header (PNG IHDR, GIF LSD,
    JPEG SOF, WebP VP8/VP8L/VP8X). Returns [None] if truncated or unreadable. *)
val parse_raster_dimensions : raster_mime -> string -> dimensions option

(** Lowercase 64-char hex SHA-256 digest of raw payload bytes. *)
val sha256_of_bytes : string -> string

(** [true] iff [token] is a well-formed 64-char lowercase hex SHA-256 digest.
    Guards the serve route path parameter; the digest is not a bearer
    capability. *)
val valid_token : string -> bool

(** Maximum raw media bytes accepted by the store, upload, and serve routes. *)
val max_raw_bytes : unit -> int

(** Encoded-carrier budget for live stream accumulation. Gives base64 expansion
    headroom over {!max_raw_bytes}. *)
val max_wire_bytes : unit -> int

(** [resolve_token ~base_dir ~token] resolves a valid SHA-256 token to its
    regular (non-symlink) on-disk path and canonical {!media_mime}. *)
val resolve_token : base_dir:string -> token:string -> (string * media_mime) option

(** [file_path_of_token ~base_dir ~token] is the regular (non-symlink) on-disk
    path of the stored media for [token], or [None] if malformed or absent. *)
val file_path_of_token : base_dir:string -> token:string -> string option

(** Verify and atomically persist a raster HTTP upload. Requires a non-empty
    payload within {!max_raw_bytes}, a declared [Content-Type] parsing to
    {!raster_mime}, non-SVG magic bytes matching the declared type, and atomic
    content-addressed write. *)
val persist_raster_upload :
  base_dir:string ->
  content_type:string option ->
  data:string ->
  (stored_media, upload_error) result

val upload_error_to_string : upload_error -> string

(** [persist_result ~base_dir ~media_type ~data] verifies [data] against
    [media_type] magic bytes, writes it atomically under its raw SHA-256 digest,
    and returns [(sha256, "/api/v1/media/<sha256>")]. *)
val persist_result :
  base_dir:string -> media_type:string -> data:string -> (string * string, string) result

(** Human-readable error for logs. Does not include the media payload; callers
    exposing failures to clients should still mask [Write_failed] details because
    filesystem errors may carry internal paths. *)
val persist_error_to_string : persist_error -> string

(** [persist_media_source_result] decodes the [AGENT_CORE] media source carrier
    ([Base64] only), verifies size and magic bytes against [media_type], and
    atomically persists to [<masc_dir>/media/]. *)
val persist_media_source_result :
  base_dir:string ->
  media_type:string ->
  source:Llm_provider.Types.media_source ->
  (string * string, persist_error) result
