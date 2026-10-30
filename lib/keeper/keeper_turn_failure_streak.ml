module Store = Keeper_turn_failure_streak_store

let increment ~base_path ~keeper_name =
  let next = Keeper_registry.get_turn_failures ~base_path keeper_name + 1 in
  (match Store.save ~base_path ~keeper_name next with
   | Ok () -> ()
   | Error error ->
     Log.Keeper.error
       ~keeper_name
       "%s: turn failure increment is process-local because durable publication failed: %s"
       keeper_name
       (Store.error_to_string error));
  Keeper_registry.increment_turn_failures ~base_path keeper_name;
  Keeper_registry.get_turn_failures ~base_path keeper_name
;;

let reset ~base_path ~keeper_name =
  match Store.clear ~base_path ~keeper_name with
  | Ok () ->
    Keeper_registry.reset_turn_failures ~base_path keeper_name;
    Keeper_registry.set_failure_reason ~base_path keeper_name None;
    true
  | Error error ->
    Log.Keeper.error
      ~keeper_name
      "%s: retaining turn failure streak because durable reset did not commit: %s"
      keeper_name
      (Store.error_to_string error);
    false
;;
