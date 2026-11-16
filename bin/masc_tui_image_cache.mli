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

val has_png_structure : ?single_frame:bool -> string -> bool
(** Check signature, positive IHDR dimensions, bounded chunks and required
    IDAT/IEND chunks. [single_frame] refuses APNG control chunks. This does
    not validate checksums or decode pixels. *)

(** {1 The fetch} *)

type ending =
  | Exited of Unix.process_status
      (** The child ended on its own, or by a signal this module did not send. *)
  | Killed_at_deadline  (** The runner killed the child at its deadline. *)
  | Cancelled
      (** The runner killed the child because it was cancelled, or did not
          start it because subprocesses were stopping. *)
(** How a run supplied to the functions below ended. Only {!run_bounded} and
    {!wait_bounded} kill a child, so only they end with [Killed_at_deadline]
    or [Cancelled]. *)

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
  | Curl_killed_at_deadline
  | Curl_cancelled
  | Curl_runner_failed of runner_failure
  | No_body_written  (** curl exited 0 and wrote no file. *)

val fetch_failure_of_ending :
  ending -> body_present:bool -> fetch_failure option
(** [None] when curl exited 0 and the body file exists. *)

val fetch_failure_text : fetch_failure -> string

type download_error =
  | Fetch_failed of fetch_failure
      (** curl did not deliver a body. Nothing is cached. *)
  | Empty_body  (** The URL delivered zero bytes. *)
  | Cache_unreadable of { detail : string }
      (** The cached file exists but could not be read. *)
  | Cached_body_too_large of { max_bytes : int }
      (** A bounded read refused the shared cache without deleting it. *)

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
  | Decoder_killed_at_deadline
  | Decoder_cancelled
  | Decoder_runner_failed of runner_failure
  | No_frame_written  (** ffmpeg exited 0 and wrote no frame. *)
  | Frame_unreadable of { detail : string }
      (** The frame file could not be read back. *)
  | Frame_not_png
      (** A converter exited 0 and wrote bytes that fail
          {!has_png_structure}. *)

val decode_failure_of_ending :
  ending -> output_present:bool -> decode_failure option
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
  ?force_fetch:bool -> ?max_bytes:int -> run:(string -> ending) -> cache_dir:string -> string ->
  (download, download_error) result
(** Fetch or reuse nonempty input bytes. Failed fetches and empty bodies are
    removed; unknown signatures remain eligible for a decoder. The result owns
    the bytes read, rather than naming the shared URL cache file. [force_fetch]
    bypasses the cache for an explicit retry and starts a new generation for
    the URL: a download that began earlier, in this process or another, still
    returns its own bytes but no longer publishes them to the shared cache
    file, so it cannot replace the retry's response. [max_bytes] bounds each read,
    retains shared cache files on refusals and does not publish a new cache
    entry. Callers must also bound the fetcher's output file while it runs. *)

val run_bounded : ?max_file_bytes:int -> deadline_seconds:float -> string -> ending
(** A [run] for the functions below that cannot hang the caller. [command] is
    one simple command, run by [sh] with the null device for input and
    output, and killed with SIGKILL when it has not exited after
    [deadline_seconds] ([Killed_at_deadline]) or when {!stop_subprocesses}
    runs ([Cancelled]). When supplied, [max_file_bytes] is a multiple of 1024
    and caps each file a child can write, including files written by its
    descendants. *)

val run_unbounded : string -> ending
(** [Unix.system] as a [run]: no deadline and no cancellation, so the ending
    is always [Exited]. *)

val wait_bounded : ?cancelled:(unit -> bool) -> deadline_seconds:float -> int -> ending
(** Reap an already-started child, killing it at the same deadline
    ([Killed_at_deadline]) or when [cancelled] becomes true ([Cancelled]).
    A child that ends before the kill takes effect keeps its own status. *)

val stop_subprocesses : unit -> unit
(** Prevent future bounded subprocesses and cancel and reap existing ones. *)

val with_decoder_output :
  run:(string -> ending) -> cache_dir:string -> prefix:string -> suffix:string ->
  (string -> string) -> ((string, decode_failure) result -> 'a) -> 'a
(** [with_decoder_output ~run ~cache_dir ~prefix ~suffix command f] runs
    [command output] and passes [f] the nonempty bytes it wrote. [output] is a
    new empty file in [cache_dir], created with O_EXCL, so no other run is
    handed its name while it exists. It stays in place while [f] runs and is
    removed when [f] returns or raises. A failure to create it is
    [Frame_unreadable]. Never removes input bytes. *)

val convert_to_png :
  run:(string -> ending) -> cache_dir:string -> string ->
  (string, conversion_failure) result
(** Try the existing converter sequence, preserving every failed attempt's
    typed status. Each converter writes its own reserved output. A runner
    failure, signal or stop ends the sequence: a descendant could still be
    running. Output that fails {!has_png_structure} is [Frame_not_png] and
    the next converter runs. A cached frame is reused only when it passes the
    same check. Input is retained even when no converter succeeds. *)

val prepare_png :
  run:(string -> ending) -> cache_dir:string -> string ->
  (string, string) result
(** Fetch, convert if needed, and read PNG bytes for the [v] path. *)

val prepare_downloaded_png :
  run:(string -> ending) -> cache_dir:string -> url:string -> download ->
  (string, string) result
(** Prepare an already captured download, retaining the source for the caller.
    A converted frame, fresh or cached, is returned only when it passes
    {!has_png_structure}; otherwise the result is an error. *)

val prepare_captured_png :
  run:(string -> ending) -> cache_dir:string -> string ->
  (string, string) result
(** Convert an already captured source through a private input snapshot,
    returning its PNG bytes without reusing or publishing a conversion cache. *)

val prepare_payload :
  run:(string -> ending) -> cache_dir:string -> string ->
  (string, string) result
(** Prepare already fetched or decoded image bytes. PNG passes through;
    other formats use the same converters as remote images. Cache publication
    is atomic and addressed by the payload, not its display label. *)

val prepare_file :
  run:(string -> ending) -> cache_dir:string -> string ->
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

type captured_copy = private { path : string; openable : bool }

val save_captured_copy : directory:string -> string -> (captured_copy, string) result
(** Save captured bytes in a private temporary file. Only recognised image
    signatures receive an image extension and are eligible for automatic open.
    Each handoff owns its copy; unretained copies are removed at shutdown. *)

val retain_captured_copy : captured_copy -> bool
(** Transfer a pending copy to the external opener or the operator. *)

val discard_captured_copy : captured_copy -> unit
(** Mark a pending copy for deletion without blocking the terminal fiber. *)

val cleanup_discarded_copies : unit -> unit
(** Remove marked copies on a worker; failed removals remain pending. *)

val stop_captured_copies : unit -> unit
(** Stop new saves and remove all copies not handed to an opener or operator. *)

val prepare_presentation :
  ?max_bytes:int -> ?max_cells:int -> run:(string -> ending) -> cache_dir:string -> display -> string ->
  (presentation, string) result
(** Prepare image bytes for the captured display. Pixel graphics require PNG;
    character cells accept PNG, JPEG or GIF, and use the existing aspect-preserving
    mosaic grid and one ffmpeg RGBA frame. All temporary files
    belong to this attempt and are removed on success or failure. Blocking: call
    only from the image acquisition worker. Original bytes are never replaced.
    [max_cells] bounds the colour frame's terminal cells by scaling its grid. *)

type remote_image =
  | Remote_unfetched
  | Remote_png of string
  | Remote_native of { source : string; png : string }
  | Remote_bounded_source of string
  | Remote_cells of { source : string; cells : (presentation, string) result }
  | Remote_busy of string option
  | Remote_bounded_failure of string
  | Remote_native_failed of { source : string; detail : string }
  | Remote_copy_ready of { copy : captured_copy; reason : string; requested_save : bool }
  | Remote_copy_failed of { source : string; reason : string; detail : string; requested_save : bool }

type remote_action =
  | Fetch_remote
  | Prepare_remote_cells of string
  | Prepare_native_source of string
  | Draw_remote_png of string
  | Draw_remote_cells of { source : string; cells : presentation }
  | Open_remote_page of { reason : string; source : string option }
  | Open_remote_copy of { copy : captured_copy; reason : string; requested_save : bool }
  | Hold_remote_source of { source : string; reason : string; detail : string; requested_save : bool }

val decide_remote : graphics:bool option -> colour:bool -> remote_image -> remote_action
(** Choose using the latest capability, which may have changed while the
    worker ran. [None] preserves the native-first attempt. *)

val invalidate_download : cache_dir:string -> string -> unit
(** Explicit user refresh only: remove this URL's input and derived frames so
    a previously refused body can be fetched again. *)
