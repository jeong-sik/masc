val extension : string
(** The one extension {!paths} answers for. Only PNG reaches the screen:
    [Masc_tui_graphics.place] says [f=100] and the terminal drops the rest, so
    naming a [.jpg] here would be offering a refusal. *)

val paths : string -> string list
(** The image files this text names, in the order they are first mentioned and
    without repeats. Found by anchoring on {!extension} and growing leftwards,
    so a path wrapped in a markdown link, in backticks, or followed by a comma
    comes back unwrapped. A URL is not a path and does not come back: it has
    no bytes on this disk. The extension is a guess about the bytes -- what
    they really are is the viewer's question, asked before it draws. *)
