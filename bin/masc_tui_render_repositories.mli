(** Repository Studio, Workspace Activity, Git Changes and File Changes screen
    entry points and viewport helpers. *)

val repository_studio_content_height :
  Masc_tui_types.state -> cols:int -> budget:int -> cursor:int -> int
(** The repository list's actual viewport, including the selected context panel.
    Keyboard page and cursor movement use the same geometry as rendering. *)

val render_workspace_activity :
  Masc_tui_types.state -> string ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_repository_changes :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_repositories :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val render_changes :
  Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option
