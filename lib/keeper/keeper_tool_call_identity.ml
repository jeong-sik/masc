type t = string

let encode_string value = Printf.sprintf "%d:%s" (String.length value) value

let create ~trace_id ?keeper_turn_id invocation =
  let schedule = Agent_sdk.Tool_contract.Invocation.schedule invocation in
  let keeper_turn =
    match keeper_turn_id with
    | Some value -> string_of_int value
    | None -> "-"
  in
  String.concat
    "|"
    [ "keeper-tool-call/v1"
    ; encode_string trace_id
    ; keeper_turn
    ; string_of_int (Agent_sdk.Tool_contract.Invocation.turn invocation)
    ; string_of_int schedule.planned_index
    ; string_of_int schedule.batch_index
    ; string_of_int schedule.batch_size
    ; encode_string (Agent_sdk.Tool_contract.Invocation.tool_use_id invocation)
    ]
;;

let to_string value = value
