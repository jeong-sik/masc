(** Terminal-specific defaults for optional control protocols. *)

type t

val detect : getenv:(string -> string option) -> t
(** [detect ~getenv] keeps optional protocols off by default in Apple
    Terminal. That terminal does not advertise Kitty keyboard or synchronized
    output support, and its window-title/render paths have crashed while this
    TUI was active. Explicit [MASC_TUI_*] settings still opt each feature in
    or out. *)

val synchronized_output : t -> bool
val kitty_keyboard : t -> bool
val dynamic_title : t -> bool
