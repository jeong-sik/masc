(** Apply Resources responses on the UI state owner fiber. Read results retain their original
    immutable contents; terminal sanitization belongs to the renderer. Catalog keys and metadata remain immutable; terminal display sanitizes copies. Transport, scheduling,
    request clocks and terminal output remain caller-owned. *)

val listed :
  Masc_tui_types.state ->
  (Masc_tui_resource_catalog.listing, string) result ->
  unit
(** Keep the open resource selected across a new listing, including a fixed
    report revision when its report is still listed. If it is absent, clamp the
    cursor and clear the reading that no longer has a listed resource. A failed
    listing retains the previous inventory and records its error. Partial inventory and per-report diagnostics stay visible in the status line. *)

val read_done :
  Masc_tui_types.state -> request:Masc_tui_resource_catalog.read_request ->
  (Masc_tui_resource_catalog.reading, string) result -> unit
(** Only the pending key and exact request owner consume the response. Text, metadata and blob payloads remain byte-for-byte
    unchanged in the retained content list. A refused read retains the previous content. *)

val open_selected :
  Masc_tui_types.state -> read:(key:Masc_tui_resource_catalog.key -> unit) -> unit
(** With a selected resource, move focus to its content pane before [read].
    An empty or invalid selection leaves state unchanged and invokes no callback. *)

val step_revision :
  Masc_tui_types.state -> direction:Masc_tui_resource_catalog.direction ->
  read:(key:Masc_tui_resource_catalog.key -> unit) -> unit
(** Request the adjacent validated revision of the open report. Does not admit
    a body, synthesize revisions or wrap at an end. MCP reads have no history. *)

val place_search_match : Masc_tui_types.state -> count:int -> index:int -> unit
(** Retain the logical match separately from the rendered scroll, whose last
    page may clamp before that row. Invalid landings or list focus do nothing. *)

val step_text_part : Masc_tui_types.state -> delta:int -> unit
(** Select an original text part for copying. Only focused, admitted Resources
    detail can move; selection clamps at either end and preserves reading state. *)
