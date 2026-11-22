(** Terminal palette (OSC 10/11/4) and stdout color-depth capability authority. *)

type rgb

val make_rgb : red:int -> green:int -> blue:int -> rgb
(** Construct an RGB triple with each channel in [0..255]; raises
    [Invalid_argument] otherwise. *)

val red : rgb -> int
val green : rgb -> int
val blue : rgb -> int
val to_packed_rgb : rgb -> Color.rgb
val of_packed_rgb : Color.rgb -> rgb
val equal_rgb : rgb -> rgb -> bool

type stdout_color_level =
  | True_color
  | Ansi256
  | Ansi16
  | Unknown

type classifier_input = {
  is_tty : bool;
  term : string option;
  colorterm : string option;
  terminfo_rgb : bool option;
  terminfo_colors : int option;
}

val classify_stdout_color_level : classifier_input -> stdout_color_level
(** Pure color-depth classifier. Precedence: usable TTY/TERM, exact
    case-insensitive [COLORTERM=truecolor] or native RGB with >= 16,777,216
    colors, >= 256 colors, >= 16 colors, else [Unknown]. *)

val stdout_color_level : unit -> stdout_color_level
(** Process-local stdout capability (probed once via terminfo/env). *)

val color_depth_of_level : stdout_color_level -> Color.depth
(** Map detected capability to {!Color.depth} (falling back conservatively to
    [Ansi16] when [Unknown]). *)

type t

val ansi_slot_count : int
(** [16]: SGR ANSI palette entries. *)

val foreground : t -> rgb
val background : t -> rgb
val ansi : t -> int -> rgb option
val equal : t -> t -> bool

type slot =
  | Foreground
  | Background
  | Ansi of int

type response =
  | Not_palette_response
  | Palette_response of {
      slot : slot;
      color : rgb option;
    }

val query : string
(** Combined OSC 10, OSC 11, and OSC 4 (0..15) ST-terminated query string. *)

val parse_response : string -> response
(** Parse one OSC body without its [ESC ]] introducer or BEL/ST terminator. *)

val of_responses :
  foreground:rgb option ->
  background:rgb option ->
  ansi:rgb option array ->
  t option
(** Builds a palette only when both foreground and background were reported. *)

type snapshot

val current : unit -> t option
val set_current : t option -> unit
val snapshot : unit -> snapshot
val snapshot_palette : snapshot -> t option
val snapshot_generation : snapshot -> int
