(** Bounded startup terminal probe filter (OSC 10/11/4 palette, CSI 16t cell
    pixel geometry, and Kitty graphics query).

    Removes recognized terminal probe replies from the captured stdin stream and
    replays all other user input bytes in exact original order. *)

type graphics_reply =
  | Graphics_supported
  | Graphics_refused of string

val equal_graphics_reply : graphics_reply -> graphics_reply -> bool
val parse_graphics_reply : string -> graphics_reply option
(** Parse a Kitty APC G reply body (without [\x1b_G] / [\x1b\\]). *)

type observation = {
  palette : Palette.t option;
  graphics : graphics_reply option;
  cell_pixels : (int * int) option;
}

val empty_observation : observation
val equal_observation : observation -> observation -> bool
val current_observation : unit -> observation
(** Process-local latest terminal capability observation (updated atomically at
    startup and on late terminal probe replies). *)

val set_current_observation : observation -> unit
(** Atomically publish the latest terminal capability observation. *)

type result = {
  palette : Palette.t option;
  graphics : graphics_reply option;
  cell_pixels : (int * int) option;
  replay : string;
}

val max_bytes : int
val query : palette:bool -> string
(** Combined CSI 16t, optional OSC 10/11/4, and Kitty 1x1 PNG graphics query. *)

type startup_status =
  | Awaiting_replies
  | Input_ready
  | Replies_ready

type decoder

val create : palette_requested:bool -> decoder
val feed : decoder -> char -> unit
val complete : decoder -> bool
val startup_status : decoder -> startup_status
val observation : decoder -> observation
val observe_palette : decoder -> Palette.slot -> Palette.rgb option -> unit
val observe_graphics : decoder -> graphics_reply -> unit
val observe_cell_pixels : decoder -> int * int -> unit
val palette : decoder -> Palette.t option
val snapshot : decoder -> result
val has_replay : decoder -> bool
val next : decoder -> next_raw:(unit -> char option) -> char option
val return_replay : decoder -> unit
val pending : decoder -> Input_decoder.pending option
val holds_incomplete_sequence : decoder -> bool
val discard_incomplete_sequence : decoder -> unit
val finish : decoder -> result
val decode : palette_requested:bool -> string -> result
