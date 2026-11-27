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
(** Default maximum non-video attachment size in bytes (20 MiB). *)

val max_bytes : unit -> int
(** Effective maximum non-video attachment size in bytes, reading
    [MASC_ATTACHMENT_MAX_BYTES] when set to a positive integer. *)

val default_max_video_bytes : int
(** Default maximum video attachment size in bytes (50 MiB). *)

val max_video_bytes : unit -> int
(** Effective maximum video attachment size in bytes, reading
    [MASC_ATTACHMENT_MAX_VIDEO_BYTES] when set to a positive integer. *)

val default_ephemeral_max_entries : int
(** Default maximum ephemeral pins retained per keeper (500). *)

val default_ephemeral_max_bytes : int
(** Default maximum total ephemeral bytes retained per keeper (20 MiB). *)

val thumb_px_buckets : int list
(** Fixed quantized pixel buckets for [?max_px=] ([160; 320; 640; 1280]).
    Requested [max_px] values snap upward to the nearest bucket and cap at
    [max_thumb_px] to bound [thumbs/] disk usage. *)

val min_thumb_px : int
(** Smallest quantized pixel bucket for [?max_px=] (160). *)

val max_thumb_px : int
(** Largest quantized pixel bucket for [?max_px=] (1280). *)

val quantize_thumb_px : int -> int
(** Snap a positive requested [max_px] upward into {!thumb_px_buckets},
    capped at {!max_thumb_px}. *)

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
  | Video
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
  | Audio_mp4
  | Audio_webm
  | Video_mp4
  | Video_webm
  | Video_quicktime

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

val is_opaque_binary : meta -> bool
(** [true] iff [meta] is an internal opaque binary persisted via {!put_opaque}
    ([mime_type = "application/octet-stream"]). HTTP responses MUST serve opaque
    binaries strictly with [Content-Type: application/octet-stream],
    [Content-Disposition: attachment], [X-Content-Type-Options: nosniff], and
    sandbox CSP — never inline. *)

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

val put_opaque :
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
(** Persist internal generated/captured binary media (e.g. FLAC/AAC/PCM/video)
    whose format is outside {!supported_mime} as downloadable
    [application/octet-stream] evidence ([kind = Document]).
    Strictly rejects [origin = User_upload] and active HTML/SVG/JS payloads.
    Public HTTP uploads MUST call {!put}, never {!put_opaque}. *)

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

type blocking_runner = { run_blocking : 'a. (unit -> 'a) -> 'a }
(** Optional offload wrapper for blocking filesystem I/O in
    {!get_image_derivative} (e.g. [Eio_unix.run_in_systhread]), while keeping
    [Process_eio] subprocess execution directly on the caller's Eio fiber. *)

val get_image_derivative :
  ?blocking:blocking_runner ->
  ?max_px:int ->
  target_format:target_format ->
  t ->
  meta:meta ->
  raw_bytes:string ->
  (string * string, derivative_error) result
(** Produce or retrieve a cached image derivative [(out_mime, out_bytes)] under
    [thumbs/<aa>/] for [?max_px=] (quantized via {!quantize_thumb_px})
    and/or [?format=png]. On [Video] attachments with [Force_png], delegates to
    {!get_video_poster}. Rejects non-image/non-video attachments with
    {!Not_an_image}. *)

val get_video_poster :
  ?blocking:blocking_runner ->
  ?max_px:int ->
  t ->
  meta:meta ->
  raw_bytes:string ->
  (string * string, derivative_error) result
(** Extract and cache a single PNG poster keyframe for a [Video] attachment via
    [ffmpeg] under [thumbs/<aa>/<sha>_poster_<px>.png] (default [px = 640],
    quantized via {!quantize_thumb_px}). Subprocess execution runs directly on
    the caller's Eio fiber (never inside [blocking]), while temp file and cache
    I/O run through [blocking]. Rejects non-video attachments with
    {!Not_an_image}. *)

val promote_to_durable : t -> id:string -> (meta option, get_error) result
(** Atomically promote an [Ephemeral] attachment to [Durable]. Returns [Ok None]
    if absent. *)

val has_ephemeral_pin : t -> keeper:string -> sha256:string -> bool
(** [true] iff [keeper] currently holds an owned regular ephemeral pin for
    the validated 64-hex [sha256] under [ephemeral/<keeper>/<sha256>]. *)

val can_keeper_read :
  t -> keeper:string -> id_or_sha256:string -> (bool, get_error) result
(** [Ok true] iff the attachment exists and is either [Durable] or currently
    pinned as ephemeral by [keeper] (even if another keeper originally wrote
    the shared blob and later evicted its own pin). [Ok false] when absent
    or ephemeral without a pin owned by [keeper]. *)

val list_ephemeral : t -> keeper:string -> (meta list, string) result
(** List currently pinned ephemeral attachments for [keeper], newest first. *)

val list_all_ephemeral_pins : t -> (Set_util.StringSet.t, string) result
(** Union of all 64-hex digests currently pinned under [ephemeral/*/].
    Returns [Ok empty] only when [ephemeral/] does not exist ([ENOENT]).
    Fails closed with [Error _] on any directory or stat read failure. *)

val list_all_blobs : t -> (string list, string) result
(** List all valid 64-hex digests present under [blobs/00..ff].
    Fails closed with [Error _] on any directory or stat read failure. *)

val blob_last_modified_at : t -> sha256:string -> (float option, string) result
(** Latest filesystem mtime across the regular blob and metadata sidecar files
    ([Ok None] when both are absent; [Error _] on invalid digest, non-regular
    entry, or stat failure). Used by GC grace-period gating. *)

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
