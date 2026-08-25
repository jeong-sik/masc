(** Terminal-reported default foreground and background colours.

    This module owns the optional palette reading. [None] means the terminal
    did not provide both OSC 10 and OSC 11 answers; it is never replaced with
    an assumed light or dark palette. *)

type rgb

val red : rgb -> int
val green : rgb -> int
val blue : rgb -> int

type t

val foreground : t -> rgb
val background : t -> rgb

type slot =
  | Foreground
  | Background

type response =
  | Not_palette_response
  | Palette_response of
      { slot : slot
      ; color : rgb option
      }

val query : string
(** One OSC 10/11 query pair, terminated with ST. *)

val parse_response : string -> response
(** Parse one OSC body without its [ESC ] introducer or BEL/ST terminator.
    A response for slot 10 or 11 remains recognized when its RGB payload is
    malformed; [color = None] prevents those bytes from leaking into input
    while keeping the palette unavailable. *)

val of_responses : foreground:rgb option -> background:rgb option -> t option
(** A palette exists only when both terminal defaults were read. *)

val current : unit -> t option
val set_current : t option -> unit
(** Process-local palette authority. Startup writes it once; later rendering
    stages read it without inventing a fallback. *)
