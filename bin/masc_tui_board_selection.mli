type selection_source =
  | List_cursor
  | Detail_post of string

(** Reindex the selected post across a list replacement, falling back to the
    bounded numeric cursor only when that identity is absent. *)
val reconcile_cursor :
  current_ids:string list ->
  cursor:int ->
  source:selection_source ->
  next_ids:string list ->
  int
