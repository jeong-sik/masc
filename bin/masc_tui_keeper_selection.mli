type navigation =
  | List_cursor of int
  | Detail_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Logs_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Message_keeper of {
      keeper_name : string;
      cursor : int;
    }

(** Reconcile Keeper navigation across a roster replacement. List, detail, and
    logs selection follow roster identity. Message navigation follows its
    explicit target even while that Keeper is unavailable, so an exact pending
    request remains recoverable. *)
val reconcile :
  current_ids:string list ->
  next_ids:string list ->
  current:navigation ->
  navigation
