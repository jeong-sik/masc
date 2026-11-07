let fields body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> Ok fields
  | _ -> Error "JSON object body required"
  | exception Yojson.Json_error detail -> Error ("invalid json: " ^ detail)
