(** Apply Resources responses on the UI state owner fiber. Read results retain their original
    immutable contents; terminal sanitization belongs to the renderer. Catalog keys and metadata remain immutable; terminal display sanitizes copies. Transport, scheduling,
    request clocks and terminal output remain caller-owned. *)

val listed :
  Masc_tui_types.state ->
  (Masc_tui_resource_catalog.listing, string) result ->
  unit
(** Keep the open key selected across a new listing. If it is absent, clamp the
    cursor and clear the reading that no longer has a listed resource. A failed
    listing retains the previous inventory and records its error. Partial inventory and per-report diagnostics stay visible in the status line. *)

val read_done :
  Masc_tui_types.state -> key:Masc_tui_resource_catalog.key ->
  (Masc_tui_mcp.resource_content list, string) result -> unit
(** Only the pending key consumes the response. Text, metadata and blob payloads remain byte-for-byte
    unchanged in the retained content list. A refused read retains the previous content. *)

val open_selected :
  Masc_tui_types.state -> read:(key:Masc_tui_resource_catalog.key -> unit) -> unit
(** With a selected resource, move focus to its content pane before [read].
    An empty or invalid selection leaves state unchanged and invokes no callback. *)
