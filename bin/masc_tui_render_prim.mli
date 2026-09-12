(** Rendering primitives shared across every surface.

    The set is computed, not curated: each value here is reached by at least
    ten of the ninety screen renderers in [Masc_tui_render], and the closure
    refers to nothing that belongs to one surface. That is why this compiles
    before them rather than beside them.

    Twelve more values live in the implementation without appearing here --
    they are the pieces the exported ones are built from, and no surface
    names them. *)


module Frame_presenter = Masc_tui_frame_presenter
module Markdown = Masc_tui_markdown

val acting_pane_reserved_cols : int ref

val acting_pane_row_targets : Masc_tui_acting_pane.row_target array ref

val acting_pane_scroll_max : int ref

val navigation_rows : int

val get_terminal_size : unit -> int * int

val frame_lines : Buffer.t -> string list

val write_two_panes :
  Buffer.t -> left_cols:int -> left:Buffer.t -> right:Buffer.t -> unit

val finish_frame :
  ?clamped:Masc_tui_types.clamped_scroll ->
  ?compact_frame:bool ->
  surface_key:string ->
  cursor:Frame_presenter.cursor ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val table_frame_enabled : bool ref

val chat_markdown_palette : closing:string -> Markdown.palette

val markdown_with_closing :
  closing:string -> width:int -> string -> string list

val document_markdown : width:int -> string -> string list

val page_unread_note : string

val page_failed_note : string

val footer_line :
  ?status:Masc_tui_footer.status_item list ->
  Masc_tui_types.state -> max_cells:int -> hints:string -> string

val keeper_split_threshold_cols : int

val keeper_roster_pane_cols : int

val finish_frame_with_strip :
  Masc_tui_types.state ->
  ?clamped:Masc_tui_types.clamped_scroll ->
  surface_key:string ->
  cursor:Frame_presenter.cursor ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val change_row_address : Masc.Tui_decode.file_change -> string

val file_change_evidence_label :
  Masc.Keeper_file_change_evidence.t option -> string option

val acting_pane_changes :
  Masc_tui_types.state -> Masc_tui_acting_pane.changes

val recent_chunk_projection :
  Masc_tui_types.state -> Masc_tui_acting.chunk_projection

val finish_surface :
  Masc_tui_types.state ->
  ?clamped:Masc_tui_types.clamped_scroll ->
  surface_key:string ->
  rows:int ->
  cols:int ->
  Buffer.t -> Frame_presenter.frame * Masc_tui_types.clamped_scroll option

type chrome_body = {
  push : string -> unit;
  push_styled : style:string -> string -> unit;
  push_selected : string -> unit;
  push_divider : unit -> unit;
  push_empty : unit -> unit;
}

val surface_chrome :
  Masc_tui_types.state ->
  terminal_rows:int ->
  cols:int ->
  surface_key:string ->
  title:string ->
  hints:string ->
  body:(budget:int -> chrome_body -> unit) ->
  Frame_presenter.frame * Masc_tui_types.clamped_scroll option

val connection_badge : Masc_tui_types.state -> string
