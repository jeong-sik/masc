(** Closed alphaTex code blocks in a chat message. *)

val of_text : string -> string list
(** [of_text text] is the body of every closed fenced block whose first info
    word is [alphatex] or [atex] (any case), in reading order.

    A fence opens on a line that starts with three backticks or three tildes
    and closes on the next line that starts with the same three characters,
    the rule the chat view draws code blocks by. A block that never closes is
    not returned. A fence of any other language is skipped up to its closing
    line. *)
