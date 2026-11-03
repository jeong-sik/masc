let announce ~base_path events =
  match Candle_observe.keepers_touched events with
  | Candle_observe.Every_keeper -> Keeper_row_broadcast.roster_changed ~base_path
  | Candle_observe.Keepers keepers ->
    List.iter (fun keeper_name -> Keeper_row_broadcast.changed ~base_path ~keeper_name) keepers
;;

let install () = Candle_ledger.install_append_observer announce
