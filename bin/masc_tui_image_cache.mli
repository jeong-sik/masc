(** Masc_tui_image_cache — what a downloaded body must be before the image
    cache may call it a hit, and what each failed process status means.

    A remote image URL can answer with something that is not an image: a
    rate-limit notice, a login page, an HTML error. If such a body is kept in
    the cache, every later preview finds a non-empty file, calls it a hit, and
    fails in the decoder. The verdict below reads the bytes, not the file size
    or the exit code. It proves only what bytes can prove: a known image
    signature, or an empty body. Everything else is left to the decoder, which
    reads formats the signature table does not name (BMP, AVIF, SVG); the
    decoder may fail for either input or environment reasons.

    File workflows below share the cache policy used by both preview paths.
    Process execution is supplied by the caller. *)

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
  | Decoder_missing  (** The shell found no decoder executable. The body is kept. *)
  | Decoder_exit of { code : int }
      (** Nonzero exit: does not distinguish bad input from execution,
          output permissions, disk space, or other environment failures. *)
  | Decoder_signaled of { signal : int }
  | Decoder_stopped of { signal : int }
  | No_frame_written  (** ffmpeg exited 0 and wrote no frame. *)
  | Frame_unreadable of { detail : string }
      (** The frame file could not be read back. *)

val decode_failure_of_status :
  Unix.process_status -> output_present:bool -> decode_failure option
(** [None] when ffmpeg exited 0 and the frame file exists. *)

val decode_failure_text : decode_failure -> string

type converter = Sips | Image_magick | Ffmpeg
type conversion_failure = (converter * decode_failure) list
val conversion_failure_text : conversion_failure -> string

val input_path : cache_dir:string -> string -> string
(** Where a URL's downloaded bytes live. Derived from the URL, so every worker
    on one URL names this one file -- which is why a download publishes by
    renaming its own attempt over it rather than writing it in place. *)

val png_path : cache_dir:string -> string -> string
(** Where a downloaded input's converted frame lives, derived from the input
    path the same way and published the same way. *)

val download :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, download_error) result
(** Fetch or reuse nonempty input bytes. Failed fetches and empty bodies are
    removed; unknown signatures remain eligible for a decoder. *)

val run_decoder :
  run:(string -> Unix.process_status) -> output_path:string -> string ->
  (string, decode_failure) result
(** Run one command after discarding any old output, returning a nonempty
    output file. Failed output is removed. Never removes input bytes. *)

val convert_to_png :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, conversion_failure) result
(** Try the existing converter sequence, preserving every failed attempt's
    typed status. Input is retained even when no converter succeeds. *)

val prepare_png :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, string) result
(** Fetch, convert if needed, and read PNG bytes for the [v] path. *)

val invalidate_download : cache_dir:string -> string -> unit
(** Explicit user refresh only: remove this URL's input and derived PNG so
    a previously refused body can be fetched again. *)
