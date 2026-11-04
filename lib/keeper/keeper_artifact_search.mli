(** Line search over a stored artifact, read in bounded chunks.

    [keeper_artifact_read] pages an artifact 16 KiB at a time. A Keeper that
    wants one error line in a 14 MB build log pages the whole file: 861 calls
    on one artifact in the 2026-11-01..04 ledger. This module finds the lines
    that contain a given text and returns where they are, so one call replaces
    the page walk and a following page read at a returned offset shows the
    surroundings.

    The scan is a pure function of a [read] function and a {!spec}. It holds
    one chunk and one unfinished line in memory at a time, so the artifact size
    does not bound it. Results do not depend on the chunk size. *)

val default_max_matches : int
val minimum_max_matches : int
val maximum_max_matches : int

val maximum_needle_bytes : int
(** Longest text a caller may search for. *)

val line_text_bytes : int
(** A hit carries at most this many bytes of its line. *)

val valid_utf8_prefix_length : string -> int
(** Length of the longest prefix that is valid UTF-8. A code point cut in half
    by a byte limit is not valid, so it is left out. *)

type spec =
  { needle : string
  ; ignore_case : bool  (** ASCII case folding only. *)
  ; max_matches : int
  ; start : int
  (** Byte offset to start at. A value returned as [next_offset] is a line
      start. Any other value starts in the middle of a line, and that line
      fragment is searched as a whole line. *)
  }

type hit =
  { offset : int  (** Byte offset of the first byte of the line. *)
  ; line_bytes : int  (** Length of the line without its line terminator. *)
  ; text : string
  (** The line cut to at most {!line_text_bytes} bytes at a UTF-8 boundary,
      without its terminator. *)
  }

type outcome =
  { hits : hit list  (** In offset order. *)
  ; next_offset : int
  (** First byte not yet examined. It is the start of a line, or [total_bytes]
      when the scan reached the end. A caller that wants more continues here. *)
  ; total_bytes : int
  ; skipped_lines : int
  (** Lines longer than [max_line_bytes] that were not searched. *)
  }

type 'e failure =
  | Read_failed of 'e
  | Offset_past_end of
      { offset : int
      ; total_bytes : int
      }
  | Short_read of
      { offset : int
      ; total_bytes : int
      }
  (** [read] returned no bytes before the end it had reported. *)

val scan :
  ?chunk_bytes:int ->
  ?max_line_bytes:int ->
  ?scan_budget_bytes:int ->
  read:(offset:int -> max_bytes:int -> (string * int, 'e) result) ->
  spec ->
  (outcome, 'e failure) result
(** [read ~offset ~max_bytes] returns up to [max_bytes] bytes at [offset] and
    the artifact's total size. A line is the bytes up to a ['\n']; one
    trailing ['\r'] is not part of it. The last line may lack a terminator.

    The scan stops when [spec.max_matches] hits were found, when it has read
    [scan_budget_bytes] since [spec.start] (it stops at the start of the line
    it is in, after at least one line was passed), or at the end. In every case
    [next_offset] is where to continue, and it is greater than [spec.start]
    unless the artifact ended there, so concatenating the hits of successive
    scans from each [next_offset] gives the hits of one scan over the whole
    artifact.

    A line is skipped, and counted in [skipped_lines], when it is longer than
    [max_line_bytes] (default 1 MiB). [chunk_bytes] (default 1 MiB) is the
    read size. [scan_budget_bytes] defaults to 16 MiB. *)
