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

type projected_color =
  | Rgb of rgb
  | Indexed of int

val stdout_color_level : unit -> stdout_color_level
(** The process-local stdout capability, backed by an internal [Lazy.t] and
    read at most once. A non-TTY stdout, unusable [TERM], or unavailable
    terminfo data remains [Unknown]. OSC foreground/background responses and
    terminal-name suffixes are not evidence for this value. *)

val best_color_for_level
  :  level:stdout_color_level
  -> rgb
  -> projected_color option
(** Project a semantic RGB colour for a known output level. [True_color]
    keeps the RGB value. [Ansi256] chooses the nearest fixed xterm colour
    (indices 16..255), with the lowest index winning a distance tie.
    [Ansi16] and [Unknown] return [None]. *)

val best_color : rgb -> projected_color option
(** Project for the process-local [stdout_color_level ()]. *)

module For_testing : sig
  type classifier_input =
    { is_tty : bool
    ; term : string option
    ; colorterm : string option
    ; terminfo_rgb : bool option
    ; terminfo_colors : int option
    }

  val classify : classifier_input -> stdout_color_level
  (** Pure classifier used by the process-local detector. Precedence is:
      usable TTY/[TERM], native RGB or exact case-insensitive
      [COLORTERM=truecolor], at least 256 colours, at least 16 colours, then
      [Unknown]. *)
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
