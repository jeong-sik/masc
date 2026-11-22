(** Streaming terminal input decoder supporting Kitty [CSI u], xterm
    [modifyOtherKeys], legacy CSI/SS3, [F1..F12], SGR & X10 mouse reports,
    bracketed paste, incremental UTF-8/Korean scalars, 2-bulsik IME helpers,
    and terminal probe replies. *)

type modifiers = {
  ctrl : bool;
  alt : bool;
  shift : bool;
}

val no_mods : modifiers
val equal_modifiers : modifiers -> modifiers -> bool

type key =
  | Char of string
  | Enter
  | Tab
  | Backspace
  | Escape
  | Delete
  | Insert
  | Up
  | Down
  | Left
  | Right
  | Home
  | End
  | Page_up
  | Page_down
  | Function of int

val equal_key : key -> key -> bool

type key_event = {
  key : key;
  mods : modifiers;
}

val equal_key_event : key_event -> key_event -> bool

type wheel_direction =
  | Wheel_up
  | Wheel_down

type mouse_event =
  | Wheel of { dir : wheel_direction; col : int; row : int }
      (** 1-based terminal column and row. *)
  | Left_press of { col : int; row : int }
  | Left_drag of { col : int; row : int }
  | Left_release of { col : int; row : int }

val equal_mouse_event : mouse_event -> mouse_event -> bool

type paste_event = {
  text : string;
  dropped_bytes : int;
}

val equal_paste_event : paste_event -> paste_event -> bool
val unescaped_path : string -> string option
(** Unescape a single-line shell-escaped absolute path dropped onto the terminal. *)

type terminal_reply =
  | Palette_reply of { slot : Palette.slot; color : Palette.rgb option }
  | Cell_pixels_reply of { width : int; height : int }
  | Graphics_reply of string

type event =
  | Key of key_event
  | Paste of paste_event
  | Mouse of mouse_event
  | Reply of terminal_reply
  | Unknown_escape
  | Invalid_utf8

type pending =
  | Prefix
  | Sequence
  | Character
  | Pasting
  | Draining

val enable_kitty_keyboard : string
val disable_kitty_keyboard : string

(** Korean 2-bulsik IME key-to-Latin replay helpers for unfocused shortcut lookup. *)
module Ime : sig
  val latin_keys : string -> string list option
  val single_latin_key : string -> string option
  val latin_text : string -> string
end

type t

val create : unit -> t
val feed : t -> char -> event list
val feed_string : t -> string -> event list
val idle : t -> event list
(** Call after a brief read timeout to flush a standalone [ESC] key or clear
    truncated prefixes. *)

val pending : t -> pending option
val cancel_pending : t -> unit
val recover_paste : t -> paste_event option
val abandon_draining : t -> unit
