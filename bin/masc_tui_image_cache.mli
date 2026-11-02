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

val has_png_structure : string -> bool
(** Check signature, positive IHDR dimensions, bounded chunks and required
    IDAT/IEND chunks. This does not validate checksums or decode pixels. *)

(** {1 The fetch} *)

type runner_failure = { error : Unix.error; operation : string; argument : string }
(** An operating-system failure starting or supervising the supplied runner,
    distinct from a command's exit status. *)

type fetch_failure =
  | Http_error_status  (** curl [--fail] saw an HTTP error status. *)
  | Operation_timeout  (** curl hit [--max-time]. *)
  | Could_not_resolve_host
  | Could_not_connect
  | Curl_missing  (** The shell found no [curl]. *)
  | Curl_exit of { code : int }  (** Any other documented curl exit code. *)
  | Curl_signaled of { signal : int }
  | Curl_stopped of { signal : int }
  | Curl_runner_failed of runner_failure
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
  | Decoder_runner_failed of runner_failure
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
(** Where [convert_to_png] stores a converted frame, derived from its input
    path. Remote downloads use a separate source-bound cache. *)

type download
(** The nonempty bytes captured by one download, independent of later cache
    replacement or invalidation. *)

val download_bytes : download -> string

val with_download_snapshot :
  cache_dir:string -> download -> (string -> 'a) -> ('a, string) result
(** Write the captured bytes to an attempt-owned input file for the duration of
    the callback. Remove that file after the callback returns or raises. *)

val download :
  ?force_fetch:bool -> run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (download, download_error) result
(** Fetch or reuse nonempty input bytes. Failed fetches and empty bodies are
    removed; unknown signatures remain eligible for a decoder. The result owns
    the bytes read, rather than naming the shared URL cache file. [force_fetch]
    bypasses the cache for an explicit retry. *)

val run_bounded : deadline_seconds:float -> string -> Unix.process_status
(** A [run] for the functions below that cannot hang the caller. [command] is
    one simple command, run by [sh] with the null device for input and
    output, and killed with SIGKILL when it has not exited after
    [deadline_seconds]; the status is then [WSIGNALED Sys.sigkill]. *)

val wait_bounded : ?cancelled:(unit -> bool) -> deadline_seconds:float -> int -> Unix.process_status
(** Reap an already-started child, killing it at the same deadline or when
    [cancelled] becomes true. *)

val stop_subprocesses : unit -> unit
(** Prevent future bounded subprocesses and cancel and reap existing ones. *)

val run_decoder :
  run:(string -> Unix.process_status) -> output_path:string -> string ->
  (string, decode_failure) result
(** Run one command after discarding any old output, returning a nonempty
    output file. Output from a failed command is removed. After a runner OS
    failure or unexpected exception, the output is left for its owner to
    remove, since callers may share the path. Never removes input bytes. *)

val convert_to_png :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, conversion_failure) result
(** Try the existing converter sequence, preserving every failed attempt's
    typed status. A runner failure stops the sequence; input is retained even
    when no converter succeeds. *)

val prepare_png :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, string) result
(** Fetch, convert if needed, and read PNG bytes for the [v] path. *)

val prepare_payload :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, string) result
(** Prepare already fetched or decoded image bytes. PNG passes through;
    other formats use the same converters as remote images. Cache publication
    is atomic and addressed by the payload, not its display label. *)

val prepare_file :
  run:(string -> Unix.process_status) -> cache_dir:string -> string ->
  (string, string) result
(** Read the selected local file and prepare PNG through the same byte-owned
    converter as decoded payloads. Reads the file's length once and refuses
    premature EOF or host read errors; never replaces the original file.
    Blocking: call only from the image acquisition worker. *)

type display = Pixel_graphics | Character_cells of { columns : int; rows : int }
(** Captured presentation and available body box in terminal cells. *)

type presentation =
  | Png of string
  | Rgba of { columns : int; pixel_rows : int; bytes : string }
(** A prepared image. RGBA has two pixel rows per character row; its dimensions
    and exact byte length are validated before it reaches the terminal owner. *)

val prepare_presentation :
  run:(string -> Unix.process_status) -> cache_dir:string -> display -> string ->
  (presentation, string) result
(** Prepare PNG bytes for the captured display. Character cells use the existing
    aspect-preserving mosaic grid and one ffmpeg RGBA frame. All temporary files
    belong to this attempt and are removed on success or failure. Blocking: call
    only from the image acquisition worker. Original bytes are never replaced. *)

val invalidate_download : cache_dir:string -> string -> unit
(** Explicit user refresh only: remove this URL's input and derived frames so
    a previously refused body can be fetched again. *)
