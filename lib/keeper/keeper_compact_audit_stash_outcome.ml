type t =
  | Inserted
  | Replaced_dropped of {
      previous_compaction_id : string;
      previous_ts_unix : float;
    }

let to_label = function
  | Inserted -> "inserted"
  | Replaced_dropped _ -> "replaced_dropped"
;;
