(** Apply Resources responses on the UI state owner fiber. Resource metadata and text
    are made terminal-safe before entering the displayed state. Transport, scheduling,
    request clocks and terminal output remain caller-owned. *)

val listed :
  Masc_tui_types.state -> (Masc_tui_mcp.resource list, string) result -> unit
(** Keep the open URI selected across a new listing. If it is absent, clamp the
    cursor and clear the reading that no longer has a listed resource. A failed
    listing retains the previous inventory and records its error. *)

val read_done :
  Masc_tui_types.state -> uri:string ->
  (Masc_tui_mcp.resource_content list, string) result -> unit
(** Only the pending URI consumes the response. Text keeps its line boundaries;
    blob payloads remain unchanged. A refused read retains the previous content. *)

val open_selected :
  Masc_tui_types.state -> read:(uri:string -> unit) -> unit
(** With a selected resource, move focus to its content pane before [read].
    An empty or invalid selection leaves state unchanged and invokes no callback. *)
