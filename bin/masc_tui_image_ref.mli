val extension : string
(** The one extension {!paths} answers for. Only PNG reaches the screen:
    [Masc_tui_graphics.place] says [f=100] and the terminal drops the rest, so
    naming a [.jpg] here would be offering a refusal. *)

val paths : string -> string list
(** The image files this text names, in the order they are first mentioned and
    without repeats. Found by anchoring on {!extension} and growing leftwards,
    so a path wrapped in a markdown link, in backticks, or followed by a comma
    comes back unwrapped. Outside ASCII a letter, mark or number is part of
    the name and comes back with the bytes it was written in; punctuation,
    symbols and spaces end the name, as ASCII punctuation does. A run of
    non-ASCII letters is read only right after a [/] ("/tmp/화면.png"),
    because elsewhere a word of unspaced prose can be glued onto it
    ("画像はscreenshot.png"); such a shape, a control or format character,
    or invalid UTF-8 gives no path rather than a joined or shorter one.
    Right after a [/] a glued word cannot be told from a directory name, so
    "/tmp/out/から/tmp/a.png" comes back whole. A
    space inside a name is not read as part of it, so such a name comes back
    from its last space.
    A URL is not a path and does not come back: it has no bytes on this disk.
    The extension is a guess about the bytes -- what they really are is the
    viewer's question, asked before it draws. *)
