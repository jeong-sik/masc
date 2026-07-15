type t = string

let stable_float value = Printf.sprintf "%.17g" value
let protocol_tag = "schedule.due_candidate"

let make ~schedule_id ~due_at ~payload_digest =
  String.concat
    "|"
    [ protocol_tag; schedule_id; stable_float due_at; payload_digest ]
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
;;

let equal = String.equal
let to_string value = value
