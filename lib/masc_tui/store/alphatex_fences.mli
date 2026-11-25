(** Closed alphaTex code blocks in a chat message. *)

val of_text : string -> string list
(** [of_text text] is the body of every closed fenced CommonMark code block
    whose language tag is [alphatex] or [atex] (any case), in reading order.
    Delegates to {!Masc_tui_ui.Markdown.alphatex_code_blocks} so [/score]
    matches the chat renderer's exact CommonMark rules. *)
