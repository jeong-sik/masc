(** Source-owned Logs pages. Client observations are process-local, and never
    borrow server authority, sequence identities, filters or detail targets. *)
type source = Server | This_tui
val source_label : source -> string
type page = {
  lp_snapshot : Masc.Tui_decode.system_log_snapshot option;
  lp_error : string option;
  lp_scroll : int;
  lp_cursor : int;
  lp_min_level : Masc.Tui_decode.system_log_level option;
  lp_category : string option;
  lp_detail_seq : int option;
  lp_detail_scroll : int;
}
type t
val empty : t
val source : t -> source
val current : t -> page
val page : source -> t -> page
val select : source -> t -> t
val update_current : (page -> page) -> t -> t
val apply : source -> (Masc.Tui_decode.system_log_snapshot, string) result -> t -> t
(** Update only the named source, including late results. Failure retains that
    source's previous snapshot. Cursor clamping uses that page's category. *)
val clear_server : t -> t
(** Retire server data/detail/navigation on workspace withdrawal, retaining its
    existing level/category preferences and all process-local observations. *)
val visible : page -> Masc.Tui_decode.system_log_entry list
val client_snapshot :
  limit:int -> min_level:Masc.Tui_decode.system_log_level option ->
  (Masc.Tui_decode.system_log_snapshot, string) result
(** Effect boundary: read only this process's bounded memory ring and use the
    shared decoder. No server request, filesystem read, draw-time refresh or
    extra timer. Unknown requested severity is an error, not a fallback floor.
    The caller applies the returned observation explicitly with [This_tui]. *)
