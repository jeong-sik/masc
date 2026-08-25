(** Terminal palette and stdout colour capability authorities.

    OSC 10/11 owns only the optional default foreground/background reading.
    It does not participate in stdout colour-depth detection. [None] means
    the terminal did not provide both answers; it is never replaced with an
    assumed light or dark palette. *)

type rgb

val make_rgb : red:int -> green:int -> blue:int -> rgb
(** Construct an RGB value. Each component must be in the inclusive range
    0..255; otherwise [Invalid_argument] is raised. *)

val red : rgb -> int
val green : rgb -> int
val blue : rgb -> int

type stdout_color_level =
  | True_color
  | Ansi256
  | Ansi16
  | Unknown

type projected_color
(** A colour already projected for the process capability. Construction stays
    inside this module so production callers cannot bypass [best_color]. *)

val stdout_color_level : unit -> stdout_color_level
(** The process-local stdout capability, backed by an internal [Lazy.t] and
    read at most once. A non-TTY stdout, unusable [TERM], or unavailable
    terminfo data remains [Unknown]. OSC foreground/background responses and
    terminal-name suffixes are not evidence for this value. *)

val best_color : rgb -> projected_color option
(** Project for the process-local [stdout_color_level ()]. *)

val fold_projected_color
  :  rgb:(rgb -> 'a)
  -> indexed:(int -> 'a)
  -> projected_color
  -> 'a
(** Eliminate an abstract projection. The [indexed] branch receives only a
    fixed xterm index in 16..255. Theme uses this to serialize SGR bytes. *)

module For_testing : sig
  type classifier_input =
    { is_tty : bool
    ; term : string option
    ; colorterm : string option
    ; terminfo_rgb : bool option
    ; terminfo_colors : int option
    }
  (** [terminfo_rgb] records capability presence only. It deliberately cannot
      establish truecolor without a matching [terminfo_colors] count. *)

  val classify : classifier_input -> stdout_color_level
  (** Pure classifier used by the process-local detector. Precedence is:
      usable TTY/[TERM], exact case-insensitive [COLORTERM=truecolor] or native
      RGB together with at least 16,777,216 colours, at least 256 colours, at
      least 16 colours, then [Unknown]. RGB capability presence alone is not
      evidence of bit depth. *)

  val best_color_for_level
    :  level:stdout_color_level
    -> rgb
    -> projected_color option
  (** Pure projection fixture. [True_color] keeps RGB, [Ansi256] chooses the
      nearest fixed xterm colour in 16..255, and [Ansi16]/[Unknown] return
      [None]. Production code uses [best_color]. *)
end

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
