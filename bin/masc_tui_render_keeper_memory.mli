val row_count : Masc_tui_types.state -> keeper_name:string -> int
(** Rows in the selected facts/changes table, from the same Keeper-keyed
    observation the renderer draws. Used only to bound local scrolling. *)

val lines :
  Masc_tui_types.state -> cols:int -> max_lines:int -> now:float ->
  keeper_name:string -> storage:(unit -> string list) -> string list
(** Compact usage, recent recording and committed formation tables. Each
    independent source keeps its loading, retained-value and failure state.
    [storage] supplies the existing health diagnostics on the storage page. *)
