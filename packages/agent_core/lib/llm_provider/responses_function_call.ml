type t =
  { call_id : string
  ; name : string
  ; arguments : string
  }

open Result.Syntax

let required_string ~field item =
  let value = match item with
    | `Assoc fields -> List.assoc_opt field fields
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
  in
  match value with
  | Some (`String s) when not (Api_common.string_is_blank s) -> Ok s
  | Some (`String _ | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
  | None -> Error (Printf.sprintf "malformed_responses_function_call:missing_%s" field)
;;

let decode item =
  let* call_id = required_string ~field:"call_id" item in
  let* name = required_string ~field:"name" item in
  let* arguments = required_string ~field:"arguments" item in
  Ok { call_id; name; arguments }
;;
