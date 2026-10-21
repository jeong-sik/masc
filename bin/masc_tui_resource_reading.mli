(** Immutable source facts behind a Resources document and its search landing.
    Retains original references, never rendered rows or copied payload bytes. *)
type t = private {
  entry : Masc_tui_resource_catalog.t;
  contents : Masc_tui_mcp.resource_content list option;
  error : string option;
  requested : bool;
  image_cursor : int;
  text_cursor : int;
  revisions : Masc_tui_resource_catalog.report list;
  presentation : Masc_tui_resource_catalog.presentation;
  metadata_expanded : bool;
  confirmation : Masc_tui_artifact_checks.status option;
}
val create : entry:Masc_tui_resource_catalog.t ->
  contents:Masc_tui_mcp.resource_content list option -> error:string option ->
  requested:bool -> image_cursor:int -> text_cursor:int ->
  revisions:Masc_tui_resource_catalog.report list ->
  presentation:Masc_tui_resource_catalog.presentation -> metadata_expanded:bool ->
  confirmation:Masc_tui_artifact_checks.status option -> t
val searchable : t -> bool
(** The current reading has admitted contents and no read failure. A retained
    same-key body may still be searched while its refresh is pending. *)

type search_position
val first : search_position
val cursor : search_position -> int
val record_landing : cols:int -> query:string -> index:int -> t -> search_position
val landing : cols:int -> query:string -> t -> search_position -> int option
(** [None] unless source facts, original content reference, presentation,
    selection, confirmation, query and pane width still match the landing.
    This is display provenance, not read or copy authority. *)
