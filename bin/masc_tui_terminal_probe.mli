(** Bounded decoding for the TUI's combined startup terminal probe.

    OSC palette replies and the existing Kitty graphics reply are removed from
    the captured byte stream. Every other byte is returned in [replay], in its
    original order, so the same input reader can serve it normally. *)

type result =
  { palette : Masc_tui_terminal_palette.t option
  ; graphics : Masc_tui_graphics.query_reply option
  ; replay : string
  }

val max_bytes : int
(** Maximum bytes one startup probe may take from the shared input stream. *)

val query : palette:bool -> string
(** The existing graphics query, optionally preceded by OSC 10/11. *)

type decoder

val create : palette_requested:bool -> decoder
val feed : decoder -> char -> unit
val complete : decoder -> bool
(** [complete] becomes true only after the graphics query and every requested
    palette slot have answered. It permits an early end without rescanning the
    captured prefix after every byte. *)

val palette : decoder -> Masc_tui_terminal_palette.t option
(** The complete palette available now, if any. O(1) and does not materialize
    or copy replay bytes. *)

val snapshot : decoder -> result
(** The answers and replay bytes available now, without flushing a partial
    terminal response. Startup reads this at its deadline, then hands the same
    decoder to the normal input reader. *)

val has_replay : decoder -> bool
val next : decoder -> next_raw:(unit -> char option) -> char option
val return_replay : decoder -> unit
(** Continue the same byte filter after startup. [next] serves decided replay
    bytes before asking [next_raw] for a suffix. [return_replay] puts back the
    one byte [next] most recently served, for UTF-8 validation pushback. *)

val finish : decoder -> result
(** Flush an incomplete or unrecognized terminal sequence into [replay]. *)

val decode : palette_requested:bool -> string -> result
(** Decode a bounded capture. Terminal-looking bytes inside bracketed paste
    remain paste bytes and are replayed unchanged. *)
