let dispatch ~dispatch arguments_json =
  match Yojson.Safe.from_string arguments_json with
  | (`Assoc _ as arguments) -> dispatch arguments
  | _ -> Error "Invalid params: expected object"
  | exception Yojson.Json_error _ -> Error "Invalid params: expected object"
;;
