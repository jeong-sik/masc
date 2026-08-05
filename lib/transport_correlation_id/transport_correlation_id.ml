type error =
  | Missing
  | Invalid_visible_ascii

let is_valid value =
  String.length value > 0
  && String.for_all
       (fun character ->
         let code = Char.code character in
         code >= 0x21 && code <= 0x7e)
       value
;;

let generate = Random_id.uuid_v7

let resolve = function
  | None -> Error Missing
  | Some value when is_valid value -> Ok value
  | Some _ -> Error Invalid_visible_ascii
;;

let error_to_string = function
  | Missing -> "observer transport requires an explicit session_id query parameter"
  | Invalid_visible_ascii ->
    "transport correlation id must contain only visible ASCII characters"
;;
