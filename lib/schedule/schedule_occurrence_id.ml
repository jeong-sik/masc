type t = string

let stable_float value = Printf.sprintf "%.17g" value
let protocol_tag = "schedule.due_candidate"

let make ~schedule_instance_id ~schedule_id ~due_at ~payload_digest =
  String.concat
    "|"
    [ protocol_tag
    ; schedule_instance_id
    ; schedule_id
    ; stable_float due_at
    ; payload_digest
    ]
  |> Agent_core_sha256.digest_string
  |> Agent_core_sha256.to_hex
;;

let to_string value = value
