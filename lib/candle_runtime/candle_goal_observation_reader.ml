let read ~base_path ~goal_id =
  let configuration = match Candle_config.load ~base_path with
    | Candle_config.Enabled _ -> Candle_goal_observation.Enabled
    | Off -> Off
    | Disabled _ -> Disabled in
  let ledger = match Candle_ledger.read ~base_path with
    | Error (Candle_ledger.Locked _) -> Candle_goal_observation.Unavailable Locked
    | Error (Store_failed _) -> Unavailable Unreadable
    | Error (Row_rejected _) -> Unavailable Invalid_row
    | Ok view when Candle_ledger.is_missing view -> Missing
    | Ok view -> Observed (Candle_goal_observation.project ~goal_id (Candle_ledger.events view)) in
  Candle_goal_observation.{ configuration; ledger }
;;
