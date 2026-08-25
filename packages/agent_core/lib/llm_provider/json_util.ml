(** Shared JSON helpers for the llm_provider library. *)

let json_type_name = function
  | `Assoc _ -> "object"
  | `List _ -> "array"
  | `String _ -> "string"
  | `Int _ | `Intlit _ | `Float _ -> "number"
  | `Bool _ -> "boolean"
  | `Null -> "null"
;;

let decode_json_with decoder raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("invalid JSON: " ^ detail)
  | json ->
    (try Ok (decoder json) with
     | Yojson.Safe.Util.Type_error (detail, offending) ->
       Error
         (Printf.sprintf
            "unexpected JSON shape: %s (got %s)"
            detail
            (json_type_name offending))
     | Yojson.Safe.Util.Undefined (detail, offending) ->
       Error
         (Printf.sprintf
            "unexpected JSON shape: %s (got %s)"
            detail
            (json_type_name offending)))
;;
