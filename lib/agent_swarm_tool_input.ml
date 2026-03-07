(** Shared JSON helpers for Agent SDK tool input parsing. *)

let json_to_string json =
  Yojson.Safe.pretty_to_string json

let extract_string key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`String s) -> Ok s
     | Some _ -> Error (Printf.sprintf "%s must be a string" key)
     | None -> Error (Printf.sprintf "missing required field: %s" key))
  | _ -> Error "input must be a JSON object"

let extract_float key json =
  match json with
  | `Assoc pairs ->
    (match List.assoc_opt key pairs with
     | Some (`Float f) -> Some f
     | Some (`Int i) -> Some (Float.of_int i)
     | _ -> None)
  | _ -> None
