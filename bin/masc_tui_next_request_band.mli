(** The NEXT REQUEST band of the context inspector.

    Draws {!Masc_tui_context_inspector.forecast}, the server's forward run of
    the turn's own composition, in tokens: the carried range from the pair's
    front, the marks it is judged against, and what the provider last
    counted. Byte figures read at the tab's scale; counts are the provider's.
    An official-client runtime is named with why it carries no range; a
    missing forecast is named, not hidden. *)

val lines
  :  prose:(string -> string list)
  -> fact:(string -> string list)
  -> safe:(string -> string)
  -> scale:Masc_tui_token_scale.t
  -> (Masc_tui_context_inspector.forecast, string) result
  -> string list
(** [prose] folds a sentence to the pane in the dim colour, [fact] folds a row
    of figures in its own colour, [safe] strips terminal control sequences
    from server-supplied text. *)
