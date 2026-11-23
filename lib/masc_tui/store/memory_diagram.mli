(** Pure adapter from {!Masc_tui_protocol.Wire_knowledge} memory activity and
    facts into {!Masc_tui_ui.Memory_lineage.chart}, PNG IHDR dimension parser,
    pure Mermaid/Tree fallback renderers, and exact diagram layout geometry
    shared by store scroll bounds, [Memory_explorer], and [App] graphics
    placement.

    Pure module: zero terminal, filesystem, or Eio I/O. *)

open Masc_tui_core
open Masc_tui_protocol
open Masc_tui_ui

val min_graphic_cols : int
(** Minimum diagram body width in terminal cells required to place Kitty/iTerm2
    pixel graphics ([12]). Narrower viewports fall back cleanly to text. *)

val min_graphic_rows : int
(** Minimum diagram body height in terminal rows required to place Kitty/iTerm2
    pixel graphics ([4]). Shorter viewports fall back cleanly to text. *)

val lineage_kind_of_wire :
  Wire_knowledge.memory_activity_kind -> Memory_lineage.event_kind
(** Exhaustive mapping of all 8 wire activity kinds into {!Memory_lineage}.
    [Activity_relation_unavailable] always stays [Relation_unavailable] and is
    never promoted. *)

val chart_of_activity :
  keeper:string ->
  activity:Wire_knowledge.keeper_memory_activity ->
  facts:Wire_knowledge.keeper_memory_facts option ->
  selected:Wire_knowledge.memory_activity_event ->
  Memory_lineage.chart option
(** Convert a Keeper's wire activity log, optional ordinary memory facts
    snapshot (used strictly to resolve unreported claim text when [facts.keeper]
    matches [keeper]), and [selected] event into a read-only connected
    {!Memory_lineage.chart}. Returns [None] when [activity.keeper <> keeper] or
    [selected.identity] is absent from [activity.events]. *)

val find_latest_event_for_fact :
  memory_id:string ->
  Wire_knowledge.keeper_memory_activity ->
  Wire_knowledge.memory_activity_event option
(** Find the latest event in [activity.events] whose [before] or [after]
    endpoints reference [memory_id], ordered by [(recorded_at_unix, revision)]. *)

val parse_png_dimensions : string -> (int * int) option
(** Safely extract [(width_px, height_px)] from PNG bytes by validating the
    exact 8-byte PNG signature, an [IHDR] chunk of length [>= 13], complete
    IHDR payload presence, and strictly positive 31-bit PNG dimensions. *)

val mermaid_source :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  kind:Knowledge_store.memory_diagram_kind ->
  Memory_lineage.chart ->
  string
(** Generate Mermaid source for [kind]: {!Memory_lineage.transition_mermaid}
    for [Diagram_pele_card] or {!Memory_lineage.mermaid} for
    [Diagram_formation_tree]. *)

val render_mermaid_fallback :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  max_width:int ->
  kind:Knowledge_store.memory_diagram_kind ->
  Memory_lineage.chart ->
  string list * string option
(** Render [chart] via {!Mermaid.render} bounded to [max_width]. If Mermaid
    refuses the source (e.g. [Too_wide]), returns wrapped raw Mermaid source
    lines paired with a concise diagnostic note instead of raising. *)

val render_tree_lines :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?keeper_name:string ->
  max_width:int ->
  Memory_lineage.chart ->
  Memory_tree.line list
(** Render [chart] into semantic {!Memory_tree.line} rows bounded by
    [max_width]. *)

val copy_source_of_chart :
  ?tz_offset_sec:int ->
  ko:bool ->
  ?now:float ->
  ?keeper_name:string ->
  max_width:int ->
  kind:Knowledge_store.memory_diagram_kind ->
  mode:Knowledge_store.memory_diagram_mode ->
  Memory_lineage.chart ->
  string
(** Build the plain-text clipboard payload ([y]) for the active diagram
    (Mermaid source or rendered formation tree text). *)

val active_memory_keeper : Model.t -> string option
(** Resolve the Keeper currently displayed in a Memory Explorer surface
    ([3 -> 기억], [4 -> Keeper -> 기억] dive, or embedded/zoomed [4 Keepers] on
    the Memory tab), or [None] when an overlay is open or another surface is
    active. *)

val active_diagram : Model.t -> Knowledge_store.memory_diagram_state option
(** Return [Some d] iff [m.knowledge.memory_diagram] is open and strictly
    matches {!active_memory_keeper}. *)

val active_memory_content_rect : Model.t -> (string * Rect.t) option
(** Exact terminal-grid screen [Rect.t] passed to
    [Memory_explorer.render_keeper_memory] for the active Keeper memory surface
    (matching [Chrome.compute_layout], [Screen_knowledge.render_memory],
    [Screen_keepers.render], and [Keeper_dive.render_memory_tab], including
    zoomed mode). Returns [None] on too-small/Micro viewports, open overlays, or
    non-memory surfaces. *)

val can_render_png_in_rect :
  content_rect:Rect.t -> Knowledge_store.memory_diagram_state -> bool
(** [true] iff [d] holds [Diagram_pele_png] in [Diagram_mode_auto] and the
    diagram body area below the 1-row header is at least
    [min_graphic_cols x min_graphic_rows]. *)

val diagram_body_rect :
  content_rect:Rect.t ->
  Knowledge_store.memory_diagram_state ->
  Rect.t * bool
(** Compute [(body_rect, has_note_row)] inside [content_rect], reserving 1 row
    for the diagram header and an optional 1 row for any note banner. Shared as
    a single SSOT by [Memory_explorer], [Update_nav], and [App]. *)

val active_diagram_body_rect : Model.t -> Rect.t option
(** Exact terminal-grid [Rect.t] of the currently open diagram's inner body
    area, or [None] when no scoped diagram is visibly rendered. *)
