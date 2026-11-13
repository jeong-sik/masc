(** Keepers list, detail pane, and turn logs screen entry points. *)

val render_keeper_list :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
(** Render the list-mode state. Plain presents an operator roster beside the
    selected Keeper's current work, human waits, last observed result and
    existing detail paths; narrow terminals stack those panes. The other
    views and the explicitly opened Story keep their axis/window renderer.
    State summarizes known scheduled wakes and partial observation in one
    cell; the time view keeps the half-hour schedule strip. Quiet separators,
    sparse history and palette-derived selection retain the same row geometry.
    Selection and fleet width/health summaries read
    the same synchronous ordered row model as the visible list. That model is
    not retained across draws or used by input handlers. Story turn records,
    including an empty successful read, are explicitly retained observations
    here: Plain does not refresh that source. The current result stays unknown
    and Enter opens Story's existing read path to observe it again. *)

val keeper_plain_page_rows :
  Masc_tui_types.state -> terminal_rows:int -> cols:int -> int option
(** The number of canonical list stops in Plain's actual visible window,
    measured by the same header, selected-card and variable row-height
    projection as the renderer. At least one for keyboard progress in a
    window too short for a row. [None] for other views or an open Story,
    whose existing page handling remains in charge. *)

val keeper_observation_reading :
  Masc_tui_types.state -> Masc_tui_detail_reading.t option
(** Capture every current Keeper-list read error with its complete reason.
    [None] when no read error is present. Uses the existing workspace/surface
    owned detail reader; reopening captures current observations again. *)

val render_keeper_detail :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_keeper_logs :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val keeper_next_text :
  ko:bool ->
  ?now:float ->
  Masc_tui_keeper_list_model.row ->
  string option
(** The next step or resting path detail for the Keeper row, Korean when [ko],
    placed at the end
    of the detail cell (right = next). Distinguishes provider stated resets vs
    MASC upper bounds, uses relative span durations, and attaches [▹] only
    when the previous turn failed. *)
