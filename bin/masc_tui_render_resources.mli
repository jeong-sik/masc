(** MCP resource inventory and document reading. Returns a frame and optional
    normalized resource scroll for the caller to apply. *)

val render_resources : Masc_tui_types.state ->
  Masc_tui_frame_presenter.frame * Masc_tui_types.clamped_scroll option

val list_page_size : Masc_tui_types.state -> rows:int -> int
(** Number of complete entries in the same list viewport the renderer uses.
    [rows] is the surface body height after composer/agenda reservation. *)

val document_viewport : Masc_tui_types.state -> rows:int -> cols:int -> int * int
(** Complete displayed document extent and content height at the current
    Resources pane width, using the same projection as drawing. [cols] excludes
    Activity and [rows] excludes composer/agenda reservation. No state changes. *)
