(** Searchable rows follow the visible list and focus. State is read-only;
    match counting retains a private memo keyed by file-row identity and query. *)

val surface_row_texts : Masc_tui_types.state -> Masc_tui_types.surface -> string list option
(** [None] disables row search when the surface or active overlay has no
    searchable list. Returned row order matches cursor positions. *)

val surface_search_count : Masc_tui_types.state -> Masc_tui_types.surface -> query:string -> int option
(** [None] means no searchable list is available. Query normalization uses
    the shared state module's canonical surface search rules. *)

type code_search_count_memo =
  { csc_rows : (string * string) list array
  ; csc_query : string
  ; csc_count : int
  }

val code_search_count_memo : code_search_count_memo option ref
(** The retained code-surface reading. A test reads the cell before and after
    a repaint to pin that the settled count is reused, not recounted. *)
