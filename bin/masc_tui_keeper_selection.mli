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
  | Calls_keeper of {
      keeper_name : string;
      cursor : int;
    }
  | Message_keeper of {
      keeper_name : string;
      cursor : int;
    }

type message_switch =
  | No_alternative
  | Switch_to of {
      keeper_name : string;
      cursor : int;
    }

(** Select the next Keeper in roster order, wrapping at the end. When the
    current chat target disappeared, the first readable Keeper is the recovery
    target. [No_alternative] means there is no different target to show. *)
val next_message_target :
  current_keeper:string -> keeper_ids:string list -> message_switch

(** Reconcile Keeper navigation across a roster replacement. List, detail, and
    logs selection follow roster identity. Message navigation follows its
    explicit target even while that Keeper is unavailable, so an exact pending
    request remains recoverable. *)
val reconcile :
  current_ids:string list ->
  next_ids:string list ->
  current:navigation ->
  navigation
