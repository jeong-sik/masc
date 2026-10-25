open Result_syntax

type stage =
  | After_input_wait_changed
  | After_assistant_collected
  | After_tool_results_appended
  | After_context_injection
  | After_rejected_response_dropped

let stage_to_string = function
  | After_input_wait_changed -> "after_input_wait_changed"
  | After_assistant_collected -> "after_assistant_collected"
  | After_tool_results_appended -> "after_tool_results_appended"
  | After_context_injection -> "after_context_injection"
  | After_rejected_response_dropped -> "after_rejected_response_dropped"

type error = Invalid_checkpoint of Error.t | Invalid_snapshot of string
let error_to_string = function
  | Invalid_checkpoint error -> Error.to_string error
  | Invalid_snapshot detail -> detail

type t =
  { stage : stage
  ; json : Yojson.Safe.t
  ; agent_name : string
  ; turn : int
  ; timestamp : float
  }

let freeze stage json =
  let+ checkpoint = Checkpoint.of_json json |> Result.map_error (fun e -> Invalid_checkpoint e) in
  {stage;json;agent_name=checkpoint.agent_name;turn=checkpoint.turn_count;
   timestamp=checkpoint.created_at}

let create ~stage checkpoint =
  let* json=Checkpoint.to_json_result checkpoint |> Result.map_error (fun e -> Invalid_checkpoint e) in
  freeze stage json

let stage value = value.stage
let agent_name value = value.agent_name
let turn value = value.turn
let timestamp value = value.timestamp
let checkpoint value = Checkpoint.of_json value.json |> Result.map_error (fun e -> Invalid_checkpoint e)
let equal left right = left.stage=right.stage && Yojson.Safe.equal left.json right.json
let pp ppf value = Format.fprintf ppf "checkpoint(%s, agent=%S, turn=%d)"
    (stage_to_string value.stage) value.agent_name value.turn
let to_yojson value = `Assoc ["stage",`String (stage_to_string value.stage);"checkpoint",value.json]

let of_yojson json =
  let malformed error = Invalid_snapshot error in
  let* ()=Execution_json.validate ~context:"checkpoint snapshot" json
      |> Result.map_error (fun e -> malformed (Execution_json.validation_error_to_string e)) in
  let* fields=Execution_json.object_fields ~context:"checkpoint snapshot"
      ~required:["stage";"checkpoint"] ~optional:[] json |> Result.map_error malformed in
  let* label=Execution_json.string_field "stage" fields |> Result.map_error malformed in
  let* stage=match label with
    | "after_input_wait_changed" -> Ok After_input_wait_changed
    | "after_assistant_collected" -> Ok After_assistant_collected
    | "after_tool_results_appended" -> Ok After_tool_results_appended
    | "after_context_injection" -> Ok After_context_injection
    | "after_rejected_response_dropped" -> Ok After_rejected_response_dropped
    | value -> Error (Invalid_snapshot ("unknown checkpoint stage: " ^ value)) in
  let* checkpoint=Execution_json.field "checkpoint" fields |> Result.map_error malformed in
  freeze stage checkpoint
