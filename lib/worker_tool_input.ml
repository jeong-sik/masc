(** Shared JSON helpers for Agent SDK tool input parsing. *)

let json_to_string json = Yojson.Safe.pretty_to_string json

let extract_string key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`String s) -> Ok s
     | Some _ -> Error (Printf.sprintf "%s must be a string" key)
     | None -> Error (Printf.sprintf "missing required field: %s" key))
  | _ -> Error "input must be a JSON object"
;;

let extract_optional_string key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`String s) -> Ok (Some s)
     | Some `Null | None -> Ok None
     | Some _ -> Error (Printf.sprintf "%s must be a string" key))
  | _ -> Error "input must be a JSON object"
;;

let extract_tasks_array json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt "tasks" pairs with
     | Some (`List []) -> Error "tasks must be a non-empty JSON array"
     | Some (`List items) ->
       let parse_item item =
         match extract_string "title" item, extract_string "description" item with
         | Ok title, Ok description -> Ok (title, description)
         | Error e, _ | _, Error e -> Error e
       in
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | item :: rest ->
           (match parse_item item with
            | Ok pair -> collect (pair :: acc) rest
            | Error e -> Error e)
       in
       collect [] items
     | Some _ -> Error "tasks must be a JSON array"
     | None -> Error "missing required field: tasks")
  | _ -> Error "input must be a JSON object"
;;

let extract_float key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
;;
