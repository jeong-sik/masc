(** The exact current Resources document. This projection reads state without
    changing retained bytes, request ownership, selection or scroll. *)
type t = Masc_tui_resource_reading.t
val current : Masc_tui_types.state -> t option
(** [None] when no inventory entry owns the pending/error/content key. *)
val entry : t -> Masc_tui_resource_catalog.t
val text_part_count : Masc_tui_types.state -> int
(** Text parts of the current admitted reading, in original response order.
    Pending reads, refusals and withdrawn inventory have no selectable parts. *)
val copy_source : Masc_tui_types.state -> ((string * string), string) result
(** Label and exact original bytes of the selected text part. Requires a ready
    workspace and focused Resources detail; never concatenates parts, decodes
    blobs, follows URIs or sanitizes payload bytes. The caller owns clipboard
    delivery; success does not establish terminal acknowledgement. *)
val export_source : Masc_tui_types.state -> (Masc_tui_resource_export.t, string) result
(** Only a ready, focused, admitted report with one original text body. *)
val copy_public_url : Masc_tui_types.state -> (string, string) result
(** The selected fixed-revision link, only after the current admitted reading
    observed sharing enabled. The configured origin is not reachability proof. *)
val external_share_change : Masc_tui_types.state ->
  ((Masc_tui_resource_catalog.report * bool), string) result
(** Decide a toggle from a known share state. Enabling requires an admitted
    original body; revoking remains possible if that body's later read fails. *)
val rows : cols:int -> t -> string list
(** [cols] is the actual document pane width, after Activity and optional
    Resources split. Both drawing and search use this projection.
    HTML document mode uses an inert structured terminal reading; source mode
    preserves syntax. Each source part's CRLF is parsed before generated
    fencing/joining and terminal sanitization. HTML document whitespace follows
    HTML parsing; original parts and copy bytes are unchanged. Source mode
    keeps standalone CR escaped. *)
val recovery_preview_fits : cols:int -> height:int -> requested:bool -> t -> bool
(** Whether the change direction and retry instruction occupy the visible
    document height when the reader is at its first row. *)
type diagram = {
  first_row : int;
  row_count : int;
  columns : int;
  image : Masc_tui_resource_diagrams.image;
}
val layout : cols:int -> t -> string list * diagram list
(** One row projection and its prepared PNG slots. Drawing, scrolling and
    placement use this same result. Source mode contains no image slots. *)
val rows_with_search : cols:int -> Masc_tui_types.state -> t ->
  (string * Masc_tui_detail_reading.search_mark) list
(** Original rows and their current literal search marks at this pane width.
    A current landing also requires the exact original reading and query.
    It retains the last search result through ordinary scrolling.
    Unadmitted content and list focus have no document marks. *)
val layout_with_search : cols:int -> Masc_tui_types.state -> t ->
  (string * Masc_tui_detail_reading.search_mark) list * diagram list
(** Search marks and image slots from one immutable layout. *)
val search_rows : cols:int -> Masc_tui_types.state -> string list option
(** Search only the currently displayed admitted content. Metadata-only,
    loading another key, failures and withdrawn inventory return [None].
    Terminal styling is removed from copies; source contents stay immutable. *)

type anchor
val capture_anchor : cols:int -> height:int -> Masc_tui_types.state -> anchor option
(** Capture the source block at the top of an admitted document reader.
    Source mode, literal search, list focus and unread/failed bodies return
    [None]. The retained content observation is part of anchor ownership. *)
val source_position : anchor -> (int * int) option
(** Original one-based part and canonical reading-input block offset when the
    anchor belongs to body source; generated document chrome returns [None]. *)
val restore_anchor : cols:int -> height:int -> Masc_tui_types.state -> anchor -> unit
(** Preserve the same source block after layout changes. Mermaid interiors
    preserve fractional block progress; explicit top and End stay explicit.
    Another content observation or reading mode cannot consume this anchor. *)
val settle_diagram : cols:int -> height:int -> Masc_tui_types.state ->
  request:Masc_tui_resource_diagrams.request -> source:string ->
  (string, string) result -> unit
(** Settle only the current preparation, preserving the reader's source anchor
    across diagram and progress/failure-header changes. *)
