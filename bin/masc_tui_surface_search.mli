(** Searchable rows follow the visible list and focus. State is read-only;
    match counting retains a private memo keyed by file-row identity and query. *)

module For_testing : sig
  type memo_snapshot
  val code_search_count_snapshot : unit -> memo_snapshot
  (** Opaque identity for checking memo reuse without exposing mutable state. *)
end

val surface_row_texts : Masc_tui_types.state -> Masc_tui_types.surface -> string list option
(** [None] disables row search when the surface or active overlay has no
    searchable list. Returned row order matches cursor positions. *)

val surface_search_count : Masc_tui_types.state -> Masc_tui_types.surface -> query:string -> int option
(** [None] means no searchable list is available. Query normalization uses
    the shared state module's canonical surface search rules. *)
