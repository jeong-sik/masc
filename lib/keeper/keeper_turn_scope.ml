let bus event_bus ~keeper_turn_id =
  match Agent_core.Caller_scope.of_string (string_of_int keeper_turn_id) with
  | Ok scope -> Agent_core.Event_bus.with_caller_scope event_bus scope
  | Error detail ->
    (* [string_of_int] never spells a blank string, the one thing
       [of_string] refuses. *)
    invalid_arg ("Keeper_turn_scope.bus: " ^ detail)
;;

let keeper_turn_id scope =
  let text = Agent_core.Caller_scope.to_string scope in
  match int_of_string_opt text with
  | Some keeper_turn_id -> Ok keeper_turn_id
  | None -> Error (Printf.sprintf "caller scope %S is not a keeper turn id" text)
;;
