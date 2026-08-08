open Result_syntax

type error =
  | Negative_planned_index
  | Negative_batch_index
  | Non_positive_batch_size
  | Invalid_terminal_schedule

let error_to_string = function
  | Negative_planned_index -> "tool schedule planned_index must be non-negative"
  | Negative_batch_index -> "tool schedule batch_index must be non-negative"
  | Non_positive_batch_size -> "tool schedule batch_size must be positive"
  | Invalid_terminal_schedule ->
    "terminal tool invocation must use planned_index=0, batch_index=0, batch_size=1, and \
     serial execution"
;;

let validate (schedule : Tool_contract.schedule) =
  if schedule.planned_index < 0
  then Error Negative_planned_index
  else if schedule.batch_index < 0
  then Error Negative_batch_index
  else if schedule.batch_size <= 0
  then Error Non_positive_batch_size
  else Ok ()
;;

let validate_completion ~completion (schedule : Tool_contract.schedule) =
  let* () = validate schedule in
  match completion with
  | Tool_contract.Continue_after_success -> Ok ()
  | Tool_contract.Terminal_after_success _ ->
    if
      schedule.planned_index = 0
      && schedule.batch_index = 0
      && schedule.batch_size = 1
      && schedule.execution_mode = Tool_contract.Serial
    then Ok ()
    else Error Invalid_terminal_schedule
;;

let validate_completion_message ~completion schedule =
  validate_completion ~completion schedule |> Result.map_error error_to_string
;;

let equal (left : Tool_contract.schedule) (right : Tool_contract.schedule) =
  left.planned_index = right.planned_index
  && left.batch_index = right.batch_index
  && left.batch_size = right.batch_size
  && left.execution_mode = right.execution_mode
;;

let to_yojson (schedule : Tool_contract.schedule) =
  `Assoc
    [ "planned_index", `Int schedule.planned_index
    ; "batch_index", `Int schedule.batch_index
    ; "batch_size", `Int schedule.batch_size
    ; "execution_mode", Tool_contract.execution_mode_to_yojson schedule.execution_mode
    ]
;;

let of_yojson json =
  let* fields =
    Execution_json.object_fields
      ~context:"tool schedule"
      ~required:[ "planned_index"; "batch_index"; "batch_size"; "execution_mode" ]
      ~optional:[]
      json
  in
  let* planned_index = Execution_json.int_field "planned_index" fields in
  let* batch_index = Execution_json.int_field "batch_index" fields in
  let* batch_size = Execution_json.int_field "batch_size" fields in
  let* execution_mode_json = Execution_json.field "execution_mode" fields in
  let* execution_mode = Tool_contract.execution_mode_of_yojson execution_mode_json in
  let schedule : Tool_contract.schedule =
    { planned_index; batch_index; batch_size; execution_mode }
  in
  let+ () = validate schedule |> Result.map_error error_to_string in
  schedule
;;
