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
