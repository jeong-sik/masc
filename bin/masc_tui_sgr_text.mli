(** Text another program wrote for a terminal, read for its colours.

    An official client's login prints what it would print to a terminal:
    grey for the version, blue for the link and the one-time code. Put
    through {!Masc.Tui_terminal_text.sanitize_terminal_text} as it is, every escape
    comes out as the six characters [\x1B[90m] in front of the text it was
    meant to colour.

    This reads the text into runs that each carry the pen the program set,
    and draws them again with this TUI's own escapes. Nothing the program
    wrote reaches the terminal as bytes: an SGR sequence becomes a {!pen},
    any other complete sequence -- a cursor move, an OSC 8 hyperlink's
    brackets, a window title -- is dropped, and what is left of the text still
    goes through the caller's sanitizer. *)

type colour =
  | Black
  | Red
  | Green
  | Yellow
  | Blue
  | Magenta
  | Cyan
  | White

type foreground =
  | Palette of colour  (** SGR 30-37, and 38;5 indices 0-7. *)
  | Bright of colour  (** SGR 90-97, and 38;5 indices 8-15. *)
  | Rgb of Masc_tui_terminal_palette.rgb
      (** SGR 38;2, and 38;5 indices 16-255 read through the xterm colour
          cube and grey ramp. Projected for this process's stdout when
          drawn. *)

type weight =
  | Regular
  | Bold
  | Dim

type pen =
  { foreground : foreground option  (** [None]: the terminal's own. *)
  ; weight : weight
  ; italic : bool
  ; underline : bool
  }

val plain : pen

type run =
  { pen : pen
  ; text : string
  }

type line = run list

val parse : string -> line list
(** One line per LF, as [String.split_on_char '\n'] cuts it, so [""] is one
    empty line. The pen carries over a line end the way it does on a
    terminal. A sequence the text ends inside is dropped: the process is
    still writing, and the next read has the rest of it. An ESC that starts
    no sequence stays in the text, for the sanitizer to show. *)

val text : line -> string
(** The line's characters without their pens. *)

val render : sanitize:(string -> string) -> line -> string
(** The line drawn with {!Masc_tui_theme.Sgr}, each run's text put through
    [sanitize] first. A line that opened a style closes it, so the result can
    be padded and cut like any other row. Under NO_COLOR the pens draw
    nothing. *)
