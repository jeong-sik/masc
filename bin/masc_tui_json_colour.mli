(** Colours for the lines of pretty-printed JSON.

    A Task's history note is pretty-printed JSON. Drawn in one colour, a key
    weighs the same as the value it names and a line is hard to pick out of
    the block. This gives a key one colour, a number and a literal ([true],
    [false], [null]) another, and leaves a string as the text it is.

    {!tokens} and {!colour_line} read a line that has already been through the
    sanitiser, so the only escapes in what {!colour_line} returns are its own. *)

val parses : string -> bool
(** [parses text] is true when [text], as it was written, is one JSON
    document. Only such text is read as JSON: prose that holds quotes or
    digits is not coloured. *)

type kind =
  | Key
  | String
  | Number
  | Literal

val tokens : string -> (kind * int * int) list
(** The tokens of one line, in order, as [(kind, start, stop)] byte ranges
    with [stop] exclusive. A key or a string is counted with its quotes, a
    number as written, a literal as [true], [false] or [null]. Punctuation and
    spaces are not tokens. A string is a [Key] when a colon follows it. *)

val colour_line : string -> string
(** [colour_line line] is [line] with every [Key], [Number] and [Literal]
    token wrapped in its colour and a reset. Without its escapes it is [line]. *)
