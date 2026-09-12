(** Masc_tui_image_cache — what a downloaded body must be before the image
    cache may call it a hit, and what each failed process status means.

    A remote image URL can answer with something that is not an image: a
    rate-limit notice, a login page, an HTML error. If such a body is kept in
    the cache, every later preview finds a non-empty file, calls it a hit, and
    fails in the decoder. The verdict below reads the bytes, not the file size
    or the exit code. It proves only what bytes can prove: a known image
    signature, or an empty body. Everything else is left to the decoder, which
    reads formats the signature table does not name (BMP, AVIF, SVG); the
    decoder's answer is then the durable one.

    Every function here is pure. The executable runs curl and ffmpeg and hands
    their process status in. *)

(** {1 Verdict by bytes} *)

type verdict =
  | Known_image of { media_type : string }
      (** The bytes carry a signature the composer's sniffer names; the file
          may stay cached. *)
  | Unknown_signature
      (** No named signature. Not a refusal: the body may be a format outside
          the sniffer's table, so the decoder decides. *)
  | Empty  (** Zero bytes. Proven not an image; the file must not be kept. *)

val verdict_of_bytes : string -> verdict
(** Decides by magic bytes through
    {!Masc.Keeper_vision_tool.sniff_image_media_type}, so the cache and the
    composer name the same signatures. *)

(** {1 The fetch} *)

type fetch_failure =
  | Http_error_status  (** curl [--fail] saw an HTTP error status. *)
  | Operation_timeout  (** curl hit [--max-time]. *)
  | Could_not_resolve_host
  | Could_not_connect
  | Curl_missing  (** The shell found no [curl]. *)
  | Curl_exit of { code : int }  (** Any other documented curl exit code. *)
  | Curl_signaled of { signal : int }
  | Curl_stopped of { signal : int }
  | No_body_written  (** curl exited 0 and wrote no file. *)

val fetch_failure_of_status :
  Unix.process_status -> body_present:bool -> fetch_failure option
(** [None] when curl exited 0 and the body file exists. *)

val fetch_failure_text : fetch_failure -> string

type download_error =
  | Fetch_failed of fetch_failure
      (** curl did not deliver a body. Nothing is cached. *)
  | Empty_body  (** The URL delivered zero bytes. The file was removed. *)
  | Cache_unreadable of { detail : string }
      (** The cached file exists but could not be read. It was removed. *)

val download_error_text : download_error -> string
(** The error as one line for a notice or a refusal. *)

(** {1 The decoder} *)

type decode_failure =
  | Decoder_missing  (** The shell found no [ffmpeg]. The body is kept. *)
  | Decoder_rejected of { code : int }
      (** ffmpeg exited non-zero on the body. The body is discarded, so the
          next session downloads it again instead of decoding the same bytes. *)
  | Decoder_signaled of { signal : int }
  | Decoder_stopped of { signal : int }
  | No_frame_written  (** ffmpeg exited 0 and wrote no frame. *)
  | Frame_unreadable of { detail : string }
      (** The frame file could not be read back. *)

val decode_failure_of_status :
  Unix.process_status -> output_present:bool -> decode_failure option
(** [None] when ffmpeg exited 0 and the frame file exists. *)

val decode_failure_discards_body : decode_failure -> bool
(** [true] only for {!Decoder_rejected}: the decoder read the body and said no.
    A missing, interrupted, or frameless decoder says nothing about the body. *)

val decode_failure_text : decode_failure -> string
