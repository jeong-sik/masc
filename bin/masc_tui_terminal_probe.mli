(** Bounded decoding for the TUI's combined startup terminal probe.

    OSC palette replies and the existing Kitty graphics reply are removed from
    the captured byte stream. Every other byte is returned in [replay], in its
    original order, so the same input reader can serve it normally. *)

type observation =
  { palette : Masc_tui_terminal_palette.t option
  ; theme_mode : Masc_tui_terminal_palette.theme_mode option
  ; graphics : Masc_tui_graphics.query_reply option
  ; cell_pixels : (int * int) option
  }
(** Immutable current replies, without copying replay bytes. A changed reply
    produces a new value; reading unchanged replies returns the same value. *)

type result =
  { palette : Masc_tui_terminal_palette.t option
  ; theme_mode : Masc_tui_terminal_palette.theme_mode option
        (** What the terminal said about its own page, and [None] where it
            said nothing. Separate from [palette] because it survives where
            the palette does not: a multiplexer passes DECSET 996 and 2031
            through and answers no OSC colour query. *)
  ; graphics : Masc_tui_graphics.query_reply option
  ; cell_pixels : (int * int) option
        (** Width and height of one character cell in pixels, from the
            terminal's answer to CSI 16 t. [None] where it did not answer,
            and a caller that needs pixels then has none: the cell grid is
            all the TUI knows about its own size. *)
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

type startup_status = Awaiting_replies | Input_ready | Replies_ready
val startup_status : decoder -> startup_status
(** Decided replay hands startup back to the input loop even while replies are
    missing. Partial replies stay owned by this same decoder. *)

val observation : decoder -> observation
val observe_palette : decoder -> Masc_tui_terminal_palette.slot ->
  Masc_tui_terminal_palette.rgb option -> unit
val observe_theme_mode : decoder -> Masc_tui_terminal_palette.theme_mode -> unit
val observe_graphics : decoder -> Masc_tui_graphics.query_reply -> unit
val observe_cell_pixels : decoder -> int * int -> unit
(** Consume typed replies from the normal input decoder after startup's byte
    filter completes. Palette collection retains its requested-slot/first-answer
    policy; graphics and cell size retain their first valid answer. Theme mode
    follows actual later notices. These grant no terminal input/effect authority. *)

val theme_mode : decoder -> Masc_tui_terminal_palette.theme_mode option
(** What the terminal has said about its own page so far. Read while the
    decoder is still live, because DECSET 2031 reports again whenever the
    reader switches theme and there is no one moment the answer is final. *)

val palette : decoder -> Masc_tui_terminal_palette.t option
(** The complete palette available now, if any. O(1) and does not materialize
    or copy replay bytes. *)

val snapshot : decoder -> result
(** The answers and replay bytes available now, without flushing a partial
    terminal response. Startup reads this at input handoff or its existing
    deadline, then hands the same
    decoder to the normal input reader. *)

val has_replay : decoder -> bool
val next : decoder -> next_raw:(unit -> char option) -> char option
val return_replay : decoder -> unit
(** Continue the same byte filter after startup. [next] serves decided replay
    bytes before asking [next_raw] for a suffix. [return_replay] puts back the
    one byte [next] most recently served, for UTF-8 validation pushback. *)

val holds_incomplete_sequence : decoder -> bool
(** [true] while the decoder keeps bytes of a sequence it has not finished and
    returns nothing for them, such as an [ESC \[ 2 0 0] head that may be a paste
    start. The decoder stays in front of the key stream for the whole session
    on a terminal that never answers the graphics query, so the input reader
    reports this hold as its own. *)

val discard_incomplete_sequence : decoder -> unit
(** Drop the bytes {!holds_incomplete_sequence} reports, on the operator's
    Ctrl-C. Does nothing when no sequence is held; replay bytes already decided
    are kept. *)

val finish : decoder -> result
(** Flush an incomplete or unrecognized terminal sequence into [replay]. *)

val decode : palette_requested:bool -> string -> result
(** Decode a bounded capture. Terminal-looking bytes inside bracketed paste
    remain paste bytes and are replayed unchanged. *)
