(** Repository Studio, Workspace Activity, Git Changes and File Changes screen
    entry points and viewport helpers. *)

val selected_repository_reading :
  Masc_tui_types.state -> Masc_tui_detail_reading.t option
(** Capture all selected repository context, including a retained-read failure,
    without using the preview's row budget. *)

val repository_studio_content_height :
  Masc_tui_types.state -> cols:int -> budget:int -> cursor:int -> int
(** The repository list's actual viewport, including the selected context panel.
    Keyboard page and cursor movement use the same geometry as rendering. *)

val repository_changes_content_height :
  Masc_tui_types.state -> cols:int -> budget:int -> cursor:int -> int
(** Visible change rows after the selected record's context and errors. *)

val repository_changes_context_visible :
  Masc_tui_types.state -> cols:int -> budget:int -> cursor:int -> bool

type repository_change_authority

val repository_changes_authority :
  Masc_tui_types.state -> surface_key:string -> terminal_rows:int -> cols:int ->
  repository_change_authority option

val same_repository_change_authority :
  repository_change_authority -> repository_change_authority -> bool

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
