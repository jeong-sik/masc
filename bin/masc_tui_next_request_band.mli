(** The NEXT REQUEST band of the context inspector.

    Draws {!Masc_tui_context_inspector.forecast}, the server's forward run of
    the turn's own arithmetic, in tokens. A candidate whose capacity carries a
    measured density reads every byte figure at that density, the exact ratio
    for its runtime; one without reads at the tab's scale. A refused window is
    drawn with its reason; a missing forecast is named, not hidden. *)

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
