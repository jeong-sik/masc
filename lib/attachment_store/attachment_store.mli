(** Unified content-addressed attachment store for MASC media.

    Layout under [<masc_dir>/attachments/]:
    - [blobs/<aa>/<64hex>]: raw binary bytes (atomic strict write; never base64,
      never text-redacted)
    - [meta/<aa>/<64hex>.json]: immutable verified metadata sidecar written
      atomically before {!put} returns
    - [ephemeral/<keeper>/<64hex>]: LRU-bounded ephemeral frame pins for
      short-lived tool captures
    - [thumbs/<aa>/<64hex>_<variant>.<ext>]: cached downscaled or PNG-transcoded
      image derivatives for [?max_px=] and [?format=png] *)

val dirname : string
(** Directory name directly below [<base>/.masc]: ["attachments"]. *)

val legacy_media_dirname : string
(** Legacy flat media directory name directly below [<base>/.masc]: ["media"].
    Registered in [Server_tool_blob_scope] so legacy workspaces never halt
    tool-blob GC. *)

val id_prefix : string
(** Canonical attachment identifier prefix: ["att_"]. *)

val url_prefix : string
(** Canonical HTTP fetch URL prefix: ["/api/v1/attachments/"]. *)

val default_max_bytes : int
(** Default maximum attachment size in bytes (20 MiB). *)

val max_bytes : unit -> int
(** Effective maximum attachment size in bytes, reading
    [MASC_ATTACHMENT_MAX_BYTES] when set to a positive integer. *)

val default_ephemeral_max_entries : int
(** Default maximum ephemeral pins retained per keeper (500). *)

val default_ephemeral_max_bytes : int
(** Default maximum total ephemeral bytes retained per keeper (20 MiB). *)

val min_thumb_px : int
(** Minimum clamped pixel bound for [?max_px=] (32). *)

val max_thumb_px : int
(** Maximum clamped pixel bound for [?max_px=] (2048). *)

type origin =
  | User_upload
  | Tool_capture
  | Model_generated
  | Connector_inbound

val origin_to_string : origin -> string
val origin_of_string : string -> origin option

type retention =
  | Durable
  | Ephemeral of { keeper : string }

val retention_to_wire_string : retention -> string

type media_kind =
  | Image
  | Audio
  | Document

val media_kind_to_string : media_kind -> string
val media_kind_of_string : string -> media_kind option

type supported_mime =
  | Image_png
  | Image_jpeg
  | Image_webp
  | Image_gif
  | Application_pdf
  | Audio_mpeg
  | Audio_wav
  | Audio_ogg
  | Audio_midi

val mime_to_string : supported_mime -> string
val media_kind_of_mime : supported_mime -> media_kind
val extension_of_mime : supported_mime -> string

val sniff_mime : string -> supported_mime option
(** Strict magic-byte sniffer for the closed set of supported formats. *)

val detect_image_dimensions : string -> (int * int) option
(** Extract positive [(width, height)] from PNG, JPEG, GIF, or WebP headers. *)

type meta =
  { id : string
  ; sha256 : string
  ; mime_type : string
  ; kind : media_kind
  ; bytes : int
  ; width : int option
  ; height : int option
  ; filename : string option
  ; origin : origin
  ; created_at_unix : float
  ; created_by : string
  ; retention : retention
  }

type put_error =
  | Empty_payload
  | Payload_too_large of
      { actual : int
      ; maximum : int
      }
  | Unsupported_or_unknown_format of { declared_mime : string option }
  | Forbidden_mime of string
  | Mime_mismatch of
      { declared : string
      ; sniffed : string
      }
  | Invalid_keeper_name of string
  | Store_io_failed of string

val put_error_to_string : put_error -> string

type get_error =
  | Invalid_id of string
  | Integrity_mismatch of
      { id : string
      ; expected : string
      ; actual : string
      }
  | Corrupt_metadata of
      { id : string
      ; detail : string
      }
  | Read_failed of string

val get_error_to_string : get_error -> string

type derivative_error =
  | Not_an_image of string
  | Invalid_max_px of int
  | Transform_failed of string

val derivative_error_to_string : derivative_error -> string

type target_format =
  | Native_format
  | Force_png

type t

val create : base_path:string -> t
(** Create a handle scoped to [<base_path>/.masc/attachments/]. Does not touch
    the filesystem until an operation runs. *)

val root_dir : t -> string
val base_path : t -> string

val is_valid_sha256 : string -> bool
(** [true] iff the input is exactly 64 lowercase hexadecimal ASCII characters. *)

val id_of_sha256 : string -> (string, string) result
(** Wrap a validated 64-hex SHA-256 digest as ["att_<64hex>"]. *)

val parse_id : string -> (string, string) result
(** Validate ["att_<64hex>"] and return the bare 64-hex [sha256]. *)

val parse_id_or_sha256 : string -> (string, string) result
(** Accept either ["att_<64hex>"] or bare ["<64hex>"] and return the bare
    64-hex [sha256]. *)

val url_of_id : string -> string
(** Canonical HTTP URL ["/api/v1/attachments/<id>"]. *)

val sanitize_filename : string -> string option
(** Strip path separators, quotes, control characters, and cap length. *)

val meta_to_wire_json : meta -> Yojson.Safe.t
(** Canonical frozen wire JSON representation with exact keys:
    [id], [attachment_id], [sha256], [url], [mime_type], [kind], [bytes],
    [width], [height], [filename], [origin], [created_at_unix], [retention]. *)

val put :
  ?max_bytes:int ->
  ?ephemeral_max_entries:int ->
  ?ephemeral_max_bytes:int ->
  ?now:float ->
  ?declared_mime:string ->
  ?filename:string ->
  origin:origin ->
  created_by:string ->
  retention:retention ->
  t ->
  bytes:string ->
  (meta, put_error) result
(** Verify, deduplicate, and atomically persist raw attachment bytes + metadata.
    Never stores base64 or runs text redaction on binary payloads.
    Re-uploading existing bytes with [Durable] promotes an [Ephemeral] record to
    [Durable]; an existing [Durable] record is never downgraded. *)

val get_meta : t -> id:string -> (meta option, get_error) result
(** Read verified metadata sidecar for canonical [att_<64hex>] id. *)

val get_meta_by_sha256 : t -> sha256:string -> (meta option, get_error) result
(** Read verified metadata sidecar for bare 64-hex [sha256]. *)

val get_bytes : t -> id:string -> (string option, get_error) result
(** Read raw bytes for canonical [att_<64hex>] id with ownership and SHA-256
    integrity verification. *)

val get_bytes_by_sha256 : t -> sha256:string -> (string option, get_error) result
(** Read raw bytes for bare 64-hex [sha256] (for [History.Stored] and
    [/api/v1/media/<sha256>] lookups) with ownership and integrity checks. *)

val get_image_derivative :
  ?max_px:int ->
  target_format:target_format ->
  t ->
  meta:meta ->
  raw_bytes:string ->
  (string * string, derivative_error) result
(** Produce or retrieve a cached image derivative [(out_mime, out_bytes)] under
    [thumbs/<aa>/] for [?max_px=] (clamped to [min_thumb_px..max_thumb_px])
    and/or [?format=png]. Rejects non-image attachments with {!Not_an_image}. *)

val promote_to_durable : t -> id:string -> (meta option, get_error) result
(** Atomically promote an [Ephemeral] attachment to [Durable]. Returns [Ok None]
    if absent. *)

val list_ephemeral : t -> keeper:string -> (meta list, string) result
(** List currently pinned ephemeral attachments for [keeper], newest first. *)

val list_all_ephemeral_pins : t -> Set_util.StringSet.t
(** Union of all 64-hex digests currently pinned under [ephemeral/*/]. *)

val list_all_blobs : t -> (string list, string) result
(** List all valid 64-hex digests present under [blobs/00..ff]. *)

val delete_unreferenced : t -> sha256:string -> (bool, string) result
(** Delete the blob, metadata sidecar, and cached thumbnails for [sha256].
    Callers pass only digests a reachability scan found unreferenced; this
    function does not check references itself. [Ok true] when a blob or
    sidecar existed, [Ok false] when neither did. *)

val extract_att_ids : string -> string list
(** Scan arbitrary text/JSON/JSONL for canonical [att_<64hex>] identifiers
    bounded cleanly away from adjacent hexadecimal characters. *)

val referenced_sha256_of_json_text : string -> Set_util.StringSet.t
(** Extract the set of referenced 64-hex SHA-256 digests named by canonical
    [att_<64hex>] identifiers in arbitrary JSON/JSONL text. *)
