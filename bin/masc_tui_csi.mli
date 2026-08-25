(** What a CSI sequence names, decided from its parameters and final byte.

    Split out of the reader so it can be tested against the bytes a terminal
    actually sends. The reader owns the timeouts and the byte pump; this owns
    the vocabulary, and a sequence it does not know keeps that shape rather
    than becoming a keystroke.

    {1 Two encodings}

    The legacy one gives a bare arrow as [ESC \[ A] and has no room for
    modifiers on most keys. The Kitty keyboard protocol -- which Ghostty,
    kitty, WezTerm, foot, Alacritty and iTerm2 speak, and which an
    application turns on with [CSI > flags u] -- reports every key with its
    modifiers, so [Shift+Up] arrives as [ESC \[ 1;2 A] and [Ctrl+P] as
    [ESC \[ 112;5 u]. Both are read here: enabling the protocol does not stop
    a terminal from sending the legacy form for keys that have one. *)

(* The modifier bitmask is read inside this module and never leaves it. What
   a caller can act on is the name, and a name already carries the modifiers
   in its prefix; exporting the mask as well would give two ways to ask the
   same question, and the tests below reach it through {!name} for that
   reason -- a mask nobody outside can hold is a mask that cannot drift from
   the name built out of it. *)

val name : parameters:string -> final:char -> string option
(** The key for one CSI sequence, or [None] when this vocabulary has none.

    Named keys are lower-case and modifiers prefix them in a fixed order —
    ["ctrl-shift-up"], never ["shift-ctrl-up"]. CSI-u Ctrl+letter sequences
    instead return the same one-byte C0 string as legacy terminals. Thus a
    binding receives one value regardless of which encoding the terminal
    uses. *)

val enable_kitty_keyboard : string
(** The escape that asks the terminal to report modifiers on every key.
    Terminals that do not know it ignore it, which is why this is written
    unconditionally rather than behind a capability query. *)

val disable_kitty_keyboard : string
(** Pops what {!enable_kitty_keyboard} pushed. Written on the way out: the
    mode belongs to this program's screen, and a shell that inherited it
    would see its own keys reported in a form it does not read. *)
