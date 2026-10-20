let delay_of_paths ~retry_interval_sec ~now paths =
  let delay = function
    | Keeper_turn_driver.Path_serving -> retry_interval_sec
    | Keeper_turn_driver.Path_resting { release_at; walk_promotes_at_release = _ } ->
      Float.max retry_interval_sec (release_at -. now)
  in
  match paths with
  | [] -> retry_interval_sec
  | first :: rest -> List.fold_left (fun soonest path -> Float.min soonest (delay path)) (delay first) rest
;;

let delay ~retry_interval_sec ~now runtime_ids =
  delay_of_paths ~retry_interval_sec ~now
    (List.map (Keeper_turn_driver.path_rest ~now) runtime_ids)

(* [walk_promotes_at_release] is [true] exactly when every rest recorded on the
   path carries a time the provider stated ([path_rest]): a quota window with
   its reset, a rate limit with a usable wait. A rest with no stated end lasts
   until the path answers, so time alone does not end it. The stores are
   stamped in epoch time when the walk records a refusal, and are read here
   against the same clock. *)
let provider_rest runtime_id : Task.Anti_rationalization.provider_rest =
  match Keeper_turn_driver.path_rest ~now:(Time_compat.now ()) runtime_id with
  | Keeper_turn_driver.Path_resting { release_at = _; walk_promotes_at_release = true } ->
    Task.Anti_rationalization.Rests_until_stated_end
  | Keeper_turn_driver.Path_resting { release_at = _; walk_promotes_at_release = false }
  | Keeper_turn_driver.Path_serving -> Task.Anti_rationalization.No_stated_rest
;;
