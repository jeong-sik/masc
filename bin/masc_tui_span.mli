(** A row built from pieces that each carry their own style.

    {1 Why this exists}

    A frame row is a string with its escapes already in it, and the renderers
    build one by concatenating styled fragments. That works while one style
    covers a whole fragment. It stops working the moment two styles overlap:
    the reset that closes the inner one also closes the outer one, so the rest
    of the row loses a background it was supposed to keep. The renderer's own
    comments record this happening -- a badge's reset flattened the emphasis
    wrapped around the line it sat in, and eight surfaces ended up differing
    by an amount nobody chose.

    A diff row is exactly that shape and worse: a gutter, a background that
    runs to the right edge, and syntax colour inside the text, three layers
    deep. Building it by concatenation would hit the same fault on every line.

    So a row is described here as pieces, and the escapes are emitted once at
    the end. Each piece re-opens the styles that still apply, which is what
    makes a piece's own reset harmless to its neighbours.

    {1 What this is not}

    Not a replacement for the frame's [string list]. A row still leaves here
    as a string, and a renderer that has no layered styling has no reason to
    come through this at all. *)

type style

val plain : style
val fg : string -> style
    (** A foreground escape, as {!Masc_tui_ansi.Ansi} spells them. Passing the
        empty string -- which is what those helpers give under [NO_COLOR] --
        is the same as {!plain}, so a caller does not have to check. *)

val bg : string -> style
val weight : string -> style
    (** Bold or dim, as {!Masc_tui_ansi.Ansi} spells them. One field because
        they are one SGR axis: a row asks for one or the other, and a value
        holding both would name a weight no terminal has. *)

val combine : style -> style -> style
(** [combine outer inner] is [inner] painted over [outer]: a colour the inner
    style sets wins, and one it leaves alone is inherited. This is the
    operation concatenation cannot express, because a string has no way to say
    "and keep what was already on". *)

type t

val text : style -> string -> t
val concat : t list -> t

val empty : t

val width : t -> int
(** Printable cells, ignoring escapes and counting a wide character as the two
    columns it occupies. What a row's budget is spent from. *)

val pad_to : int -> style -> t -> t
(** Extend to [width] cells with spaces carrying [style]. Shorter than the
    current width is left alone: a row that already overflows is trimmed by
    {!truncate}, and silently cutting here would make padding a second place
    that shortens.

    The padding carries a style because a background that stops at the last
    character is not a background -- a diff line's colour has to reach the
    right edge or the rows look ragged. *)

val truncate : int -> t -> t
(** Cut to at most [width] printable cells.

    Cuts between characters, never inside one: a character wider than what is
    left is dropped whole, because half a syllable is not a narrower syllable
    but a byte sequence the terminal reads as something else. And never inside
    an escape -- the escapes are not in the value yet, which is the point of
    cutting here rather than on the finished string.

    Not [Masc_tui_message_layout.fit_width], which pads to the width and marks
    the cut with a tilde. That is what a column wants; this is what a budget
    wants. *)

val render : t -> string
(** The row as one string, escapes and all. Every run closes what it opened,
    so a caller can put the result anywhere a plain string goes. *)
