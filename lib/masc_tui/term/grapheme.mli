(** UAX #29 grapheme cluster segmentation, UAX #11 cell widths, ASCII fast path,
    and ingress control-character stripping for terminal injection safety. *)

type cluster = {
  start_offset : int;
  end_offset : int;
  cell_width : int;
}

val utf8_scalar_byte_length : char -> int option
(** Expected UTF-8 scalar byte length from a leading byte, or [None] if invalid. *)

val scalar_width : Uchar.t -> int
(** Terminal cell width of one Unicode scalar ([0], [1], or [2]). *)

val is_all_printable_ascii : string -> bool
(** True when every byte is printable ASCII ([0x20..0x7E]). Zero allocation. *)

val is_simple_ascii_or_cjk_hangul : string -> bool
(** True when every scalar is printable ASCII, a non-combining width-1 UI
    symbol, precomposed Hangul syllable, or CJK Unified Ideograph. Zero
    allocation. *)

val sanitize_controls : string -> string
(** Strip raw ANSI CSI/OSC sequences, C0/DEL/C1 control characters, and unsafe
    default-ignorable invisibles (bidi overrides, lone joiners/selectors, tag
    spoofing) while keeping printable ASCII, Korean/CJK, and valid emoji
    sequences intact. Zero-allocation fast path for printable ASCII. *)

val iter_sanitized_clusters :
  string -> (start_offset:int -> end_offset:int -> cell_width:int -> unit) -> unit
(** Iterate UAX #29 extended grapheme clusters directly over an already-sanitized
    string (output of {!sanitize_controls}) without re-sanitizing. Offsets index
    the passed string directly. *)

val iter_clusters :
  string ->
  (text:string -> start_offset:int -> end_offset:int -> cell_width:int -> unit) ->
  unit
(** Sanitize [s] once via {!sanitize_controls} and iterate UAX #29 clusters.
    The callback receives [~text], the sanitized string indexed by
    [start_offset]..[end_offset], preventing accidental slicing of raw input. *)

val segment : string -> string * cluster list
(** Return [(sanitized_text, clusters)] where every {!cluster}'s offsets index
    [sanitized_text]. *)
val split_clusters : string -> (string * int) list
val display_width : string -> int
(** Exact terminal column width after control stripping. Fast-paths printable ASCII. *)

val truncate_to_width : max_width:int -> ?ellipsis:string -> string -> string
(** Truncate cleanly on a grapheme cluster boundary so the returned string fits
    within [max_width] terminal columns (appending [ellipsis], default ["…"],
    when truncated and space permits). *)

val pad_right : width:int -> string -> string
(** Fit [s] to exactly [width] terminal display columns: truncate cleanly on a
    grapheme cluster boundary when wider than [width], or right-pad with ASCII
    spaces when narrower. *)
