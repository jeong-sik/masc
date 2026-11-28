(** Typed attachment reference, MIME sniffing, local pasted-path normalization,
    and canonical [/api/v1/attachments] wire codecs shared across chat, board,
    journal, HTTP client, and display pipelines. *)

type kind =
  | Kind_image
  | Kind_audio
  | Kind_video
  | Kind_document

type t = {
  id : string;
  attachment_id : string;
  sha256 : string option;
  url : string;
  mime_type : string;
  kind : kind;
  bytes : int;
  width : int option;
  height : int option;
  filename : string option;
  origin : string option;
  retention : string option;
}

val equal_kind : kind -> kind -> bool
val equal : t -> t -> bool

val kind_to_string : kind -> string
val kind_of_string : string -> kind option
val kind_of_mime : string -> kind

val attachments_upload_path : string
val attachment_path_prefix : string
val media_path_prefix : string

type served_path =
  | Attachment_id of string  (** The rest of the path after {!attachment_path_prefix}. *)
  | Media_token of string  (** The rest of the path after {!media_path_prefix}. *)

val served_path : string -> served_path option
(** The server route a path names, with the rest of the path as written.
    [None] for any other path. *)

val is_attachment_path : string -> bool
(** [true] for canonical [/api/v1/attachments/<id>] and server-delegated
    [/api/v1/media/<sha|id>] paths that accept [?format=png], [?max_px=], and
    [?download=1]. *)
val attachment_path : string -> string
val attachment_meta_path : string -> string

val encode_filename_header : string -> string
(** Extract the basename, strip ASCII control characters (including CR/LF), and
    percent-encode bytes outside RFC 3986 unreserved characters so [X-Filename]
    is HTTP-header-safe and round-trips cleanly through server [Uri.pct_decode]. *)

val attachment_render_path :
  ?format:string -> ?max_px:int -> ?download:bool -> string -> string
(** Append query parameters ([format], [max_px], [download=1]) onto an
    attachment or media path ({!is_attachment_path}). Other paths are returned
    unchanged. *)

val is_raster_image_mime : string -> bool
(** [true] for [image/png], [image/jpeg], [image/webp], and [image/gif]. *)

val is_video_mime : string -> bool
(** [true] for [video/mp4], [video/webm], and [video/quicktime] (plus aliases). *)

val is_playable_media_mime : string -> bool
(** [true] for supported audio/MIDI or video MIME types playable via [/play]. *)

val normalize_mime : string -> string
(** Normalize common MIME aliases ([audio/x-midi]/[audio/mid] -> [audio/midi],
    [audio/x-wav]/[audio/wave] -> [audio/wav], [video/x-m4v] -> [video/mp4],
    [image/jpg] -> [image/jpeg], [audio/x-m4a] -> [audio/mp4]). *)

val max_non_video_upload_bytes : int
(** Default 20 MiB upload limit for images, audio, and documents. *)

val max_video_upload_bytes : int
(** Default 50 MiB upload limit for video attachments. *)

val max_upload_bytes_for_mime : string -> int
(** Return {!max_video_upload_bytes} for video MIME types and
    {!max_non_video_upload_bytes} otherwise. *)

val extension_of_mime : string -> string
(** Canonical file extension including leading dot (e.g. [".png"], [".jpg"]). *)

val sniff_mime : ?filename:string -> string -> string option
(** Detect supported attachment MIME type from raw magic bytes first, rejecting
    forbidden web-active payloads ([image/svg+xml], [text/html]). Falls back to
    safe filename extension only when bytes lack a known container signature. *)

val has_supported_media_extension : string -> bool
(** [true] for supported image, PDF, and audio file extensions. *)

val normalize_pasted_path : string -> string option
(** Pure normalization of a single bracketed-paste token into a local path:
    strips surrounding whitespace/quotes, unescapes shell/Finder backslash
    escapes (e.g. [\ ]), decodes [file://] URIs, and rejects multiline or
    non-path text. *)

val resolve_local_media_file : string -> string option
(** Return [Some path] when [normalize_pasted_path] resolves to an existing
    regular local file with a supported media extension (or sniffed media
    magic bytes). *)

val decode_attachment_ref : Yojson.Safe.t -> (t, string) result
(** Decode a canonical server [AttachmentRef] JSON object. *)

val decode_upload_response : Yojson.Safe.t -> (t, string) result
(** Decode [POST /api/v1/attachments] [{ "ok": true, "data": <AttachmentRef> }]
    or a bare [AttachmentRef] object. *)

val encode_attachment_ref : t -> Yojson.Safe.t
(** Encode an [AttachmentRef] for [POST /api/v1/keepers/chat/stream]
    [attachments[]] without inline base64. *)

val encode_user_block : t -> Yojson.Safe.t
(** Encode [{ "type": "attachment", "attachment_id": id }] for [user_blocks[]]. *)

val format_chip : t -> string
(** Compact chip label for composer tray and metadata captions, e.g.
    ["[img: screenshot.png 1280x720]"] or ["[pdf: report.pdf 42 KB]"]. *)

val document_chip_label : string -> string
(** The chip label of a document with this MIME type: its format's extension
    without the dot ([pdf], [docx], [hwp]), or [file] for a type outside
    {!Document_format}. *)
