type t =
  | Yojson_parse_error
  | Io_error
  | Type_error
  | Other

let classify : exn -> t = function
  | Yojson.Json_error _ -> Yojson_parse_error
  | Sys_error _ | Unix.Unix_error _ -> Io_error
  | Failure _ | Yojson.Safe.Util.Type_error _ -> Type_error
  | _ -> Other
;;

let to_label = function
  | Yojson_parse_error -> "yojson_parse_error"
  | Io_error -> "io_error"
  | Type_error -> "type_error"
  | Other -> "other"
;;
