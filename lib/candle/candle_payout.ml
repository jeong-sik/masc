(* See candle_payout.mli. *)

let owes_already ~goal_id events =
  List.exists
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Payout_owed owed -> String.equal owed.goal_id goal_id
       | Candle_event.Snapshot _ -> false)
    events
;;

let snapshot_pass ~goal_id ~request_id ~passed_at events =
  List.find_map
    (fun (event : Candle_event.t) ->
       match event.body with
       | Candle_event.Snapshot snapshot
         when String.equal snapshot.goal_id goal_id
              && String.equal snapshot.request_id request_id
              && String.equal (Candle_time.to_rfc3339 snapshot.passed_at) passed_at ->
         Some snapshot.passed_at
       | Candle_event.Snapshot _ | Candle_event.Payout_owed _ -> None)
    events
;;

let owed_pass ~goal_id ~request_id ~passed_at events =
  if owes_already ~goal_id events
  then None
  else snapshot_pass ~goal_id ~request_id ~passed_at events
;;
