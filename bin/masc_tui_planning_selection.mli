type navigation =
  | List_cursor of int
  | Detail_goal of {
      goal_id : string;
      cursor : int;
    }

(** Reconcile Planning navigation across a visible goal-list replacement.
    Existing goal identity wins; a missing identity falls back to the bounded
    numeric cursor and list mode. *)
val reconcile :
  current_ids:string list ->
  next_ids:string list ->
  current:navigation ->
  navigation
