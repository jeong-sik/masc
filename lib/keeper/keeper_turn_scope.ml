type t = { caller_scope : Agent_core.Caller_scope.t; turn_id : int }

let create ~keeper_turn_id =
  (* The bus's entropy-backed identity generator does not fall back to a
     display counter, clock or process id if entropy is unavailable. *)
  let execution_id = Agent_core.Event_bus.fresh_id () in
  let encoded = Yojson.Safe.to_string
      (`Assoc ["execution_id", `String execution_id;
               "keeper_turn_id", `Int keeper_turn_id]) in
  match Agent_core.Caller_scope.of_string encoded with
  | Ok caller_scope -> { caller_scope; turn_id = keeper_turn_id }
  | Error detail ->
    (* A serialized JSON object is never blank. *)
    invalid_arg ("Keeper_turn_scope.create: " ^ detail)
;;

let turn_id scope = scope.turn_id
let bus event_bus ~scope = Agent_core.Event_bus.with_caller_scope event_bus scope.caller_scope
let filter scope = Agent_core.Event_bus.filter_caller_scope scope.caller_scope

let keeper_turn_id scope =
  match Yojson.Safe.from_string (Agent_core.Caller_scope.to_string scope) with
  | `Assoc fields ->
    (match List.sort (fun (a, _) (b, _) -> String.compare a b) fields with
     | ["execution_id", `String execution_id; "keeper_turn_id", `Int turn_id] ->
       (match Agent_core.Caller_scope.of_string execution_id with
        | Ok _ -> Ok turn_id
        | Error detail -> Error ("invalid execution identity: " ^ detail))
     | _ -> Error "keeper scope requires exactly execution_id and keeper_turn_id")
  | _ -> Error "keeper scope must be an object"
  | exception Yojson.Json_error detail -> Error ("invalid keeper scope: " ^ detail)
;;
