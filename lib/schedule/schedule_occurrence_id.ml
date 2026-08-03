type t = string

let stable_float value = Printf.sprintf "%.17g" value
let protocol_tag = "schedule.due_candidate"

let make ~schedule_id ~requested_at ~due_at ~payload_digest =
  String.concat
    "|"
    [ protocol_tag
    ; schedule_id
    ; stable_float requested_at
    ; stable_float due_at
    ; payload_digest
    ]
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let of_string value =
  let is_lower_hex = function
    | '0' .. '9' | 'a' .. 'f' -> true
    | _ -> false
  in
  if String.length value = 64 && String.for_all is_lower_hex value
  then Ok value
  else Error "schedule occurrence id must be a lowercase SHA-256 digest"
;;

let equal = String.equal
let to_string value = value
