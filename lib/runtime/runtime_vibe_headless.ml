type error =
  { stage : string
  ; detail : string
  }

let error_to_string { stage; detail } = Printf.sprintf "Vibe headless %s: %s" stage detail
let fail stage fmt = Printf.ksprintf (fun detail -> Error { stage; detail }) fmt
let ( let* ) = Result.bind

let parse stage text =
  match Yojson.Safe.from_string text with
  | json -> Ok json
  | exception Yojson.Json_error detail -> Error { stage; detail }
;;

let as_object stage = function
  | `Assoc fields -> Ok fields
  | _ -> fail stage "expected a JSON object"
;;

let present stage fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> fail stage "missing field %S" name
;;

let to_string stage name = function
  | `String value -> Ok value
  | _ -> fail stage "field %S is not a string" name
;;

let to_int stage name = function
  | `Int value -> Ok value
  | _ -> fail stage "field %S is not an integer" name
;;

(* JSON has one number type; Vibe writes a whole cost as [0.0], but an
   integer literal names the same number. *)
let to_float stage name = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> fail stage "field %S is not a number" name
;;

let string_field stage fields name =
  let* value = present stage fields name in
  to_string stage name value
;;

let int_field stage fields name =
  let* value = present stage fields name in
  to_int stage name value
;;

(* A field Vibe always writes, [null] when it has no value. *)
let nullable_field stage fields name decode =
  let* value = present stage fields name in
  match value with
  | `Null -> Ok None
  | value -> Result.map Option.some (decode value)
;;

(* {1 export.json} *)

type outcome =
  | Finished
  | Usage_error
  | Config_error
  | Infrastructure_failure
  | Turn_limit
  | Token_limit
  | Price_limit
  | Deadline
  | Terminated
  | Length
  | Refusal
  | Aborted
  | Unrecognized_outcome of string

(* The [vibe -p] process is the Rust [vibe-rs], which writes export.json
   with the same twelve outcome strings in the same order as Vibe's Python
   [RunOutcome]. The exit codes are read from that Python mirror,
   [RunOutcome.exit_code] in vibe/app_server/run_export.py, 3.1.0; the Rust
   binary's own table is compiled in and was not read. *)
let exit_code_of_outcome = function
  | Finished -> Some 0
  | Usage_error | Config_error -> Some 1
  | Infrastructure_failure -> Some 2
  | Turn_limit | Token_limit | Price_limit | Deadline | Terminated | Length | Refusal ->
    Some 3
  | Aborted -> Some 4
  | Unrecognized_outcome _ -> None
;;

type stop_reason =
  | Interrupted
  | Limit
  | Unrecognized_stop_reason of string

type usage =
  { input_tokens : int
  ; output_tokens : int
  ; cached_input_tokens : int
  ; total_tokens : int
  }

type run_error =
  { message : string
  ; code : string option
  }

type export =
  { outcome : outcome
  ; stop_reason : stop_reason option
  ; error : run_error option
  ; session_id : string option
  ; usage : usage option
  ; cost_usd : float option
  ; steps : int option
  ; vibe_version : string
  ; exit_code : int
  }

let export_schema_version = 1

let outcome_to_wire = function
  | Finished -> "finished"
  | Usage_error -> "usage_error"
  | Config_error -> "config_error"
  | Infrastructure_failure -> "infrastructure_failure"
  | Turn_limit -> "turn_limit"
  | Token_limit -> "token_limit"
  | Price_limit -> "price_limit"
  | Deadline -> "deadline"
  | Terminated -> "terminated"
  | Length -> "length"
  | Refusal -> "refusal"
  | Aborted -> "aborted"
  | Unrecognized_outcome value -> value
;;

let outcome_of_wire = function
  | "finished" -> Finished
  | "usage_error" -> Usage_error
  | "config_error" -> Config_error
  | "infrastructure_failure" -> Infrastructure_failure
  | "turn_limit" -> Turn_limit
  | "token_limit" -> Token_limit
  | "price_limit" -> Price_limit
  | "deadline" -> Deadline
  | "terminated" -> Terminated
  | "length" -> Length
  | "refusal" -> Refusal
  | "aborted" -> Aborted
  | other -> Unrecognized_outcome other
;;

let stop_reason_of_wire = function
  | "interrupted" -> Interrupted
  | "limit" -> Limit
  | other -> Unrecognized_stop_reason other
;;

let decode_usage stage json =
  let* fields = as_object stage json in
  let* input_tokens = int_field stage fields "input_tokens" in
  let* output_tokens = int_field stage fields "output_tokens" in
  let* cached_input_tokens = int_field stage fields "cached_input_tokens" in
  let* total_tokens = int_field stage fields "total_tokens" in
  Ok { input_tokens; output_tokens; cached_input_tokens; total_tokens }
;;

let decode_run_error stage json =
  let* fields = as_object stage json in
  let* message = string_field stage fields "message" in
  let* code = nullable_field stage fields "code" (to_string stage "code") in
  Ok { message; code }
;;

let decode_export text =
  let stage = "export.json" in
  let* json = parse stage text in
  let* fields = as_object stage json in
  let* schema_version = int_field stage fields "schema_version" in
  if schema_version <> export_schema_version
  then
    fail stage "schema_version %d, this decoder reads %d" schema_version
      export_schema_version
  else
    let* outcome = Result.map outcome_of_wire (string_field stage fields "outcome") in
    let* stop_reason =
      nullable_field stage fields "stop_reason" (fun value ->
        Result.map stop_reason_of_wire (to_string stage "stop_reason" value))
    in
    let* error = nullable_field stage fields "error" (decode_run_error stage) in
    let* session_id =
      nullable_field stage fields "session_id" (to_string stage "session_id")
    in
    let* usage = nullable_field stage fields "usage" (decode_usage stage) in
    let* cost_usd = nullable_field stage fields "cost_usd" (to_float stage "cost_usd") in
    let* steps = nullable_field stage fields "steps" (to_int stage "steps") in
    let* vibe_version = string_field stage fields "vibe_version" in
    let* exit_code = int_field stage fields "exit_code" in
    Ok
      { outcome
      ; stop_reason
      ; error
      ; session_id
      ; usage
      ; cost_usd
      ; steps
      ; vibe_version
      ; exit_code
      }
;;

(* {1 Session entries} *)

type role =
  | User
  | Assistant
  | Unrecognized_role of string

type content_part =
  | Text of string
  | Unrecognized_part of string

type effect_status =
  | Completed
  | Failed
  | Unrecognized_effect_status of string

type effect_error_code =
  | Tool_denied
  | Unrecognized_effect_error of string

type effect_error =
  { code : effect_error_code
  ; message : string
  }

type entry =
  | Message of
      { session_id : string
      ; turn_id : string
      ; role : role
      ; content : content_part list
      }
  | Reasoning of
      { session_id : string
      ; turn_id : string
      ; text : string
      }
  | Effect of
      { session_id : string
      ; turn_id : string
      ; tool_name : string
      ; status : effect_status
      ; error : effect_error option
      }
  | Unrecognized_entry of
      { kind : string
      ; session_id : string
      ; turn_id : string
      }

let role_of_wire = function
  | "user" -> User
  | "assistant" -> Assistant
  | other -> Unrecognized_role other
;;

let effect_status_of_wire = function
  | "completed" -> Completed
  | "failed" -> Failed
  | other -> Unrecognized_effect_status other
;;

let effect_error_code_of_wire = function
  | "tool_denied" -> Tool_denied
  | other -> Unrecognized_effect_error other
;;

let decode_part stage json =
  let* fields = as_object stage json in
  let* kind = string_field stage fields "type" in
  match kind with
  | "text" ->
    let* text = string_field stage fields "text" in
    Ok (Text text)
  | other -> Ok (Unrecognized_part other)
;;

let decode_list stage name decode = function
  | `List items ->
    List.fold_left
      (fun acc item ->
         let* decoded = acc in
         let* value = decode item in
         Ok (value :: decoded))
      (Ok []) items
    |> Result.map List.rev
  | _ -> fail stage "field %S is not a list" name
;;

(* [state.error] is absent on an effect that succeeded and an object on one
   that did not; a [null] says the same as absence. *)
let decode_effect_error stage state =
  match List.assoc_opt "error" state with
  | None | Some `Null -> Ok None
  | Some json ->
    let* fields = as_object stage json in
    let* code = string_field stage fields "code" in
    let* message = string_field stage fields "message" in
    Ok (Some { code = effect_error_code_of_wire code; message })
;;

let decode_entry_json json =
  let stage = "session entry" in
  let* fields = as_object stage json in
  let* kind = string_field stage fields "type" in
  let* session_id = string_field stage fields "sessionId" in
  let* turn_id = string_field stage fields "turnId" in
  match kind with
  | "message" ->
    let* role = Result.map role_of_wire (string_field stage fields "role") in
    let* content_json = present stage fields "content" in
    let* content = decode_list stage "content" (decode_part stage) content_json in
    Ok (Message { session_id; turn_id; role; content })
  | "reasoning" ->
    let* text = string_field stage fields "text" in
    Ok (Reasoning { session_id; turn_id; text })
  | "effect" ->
    let* detail_json = present stage fields "detail" in
    let* detail = as_object stage detail_json in
    let* tool_name = string_field stage detail "toolName" in
    let* state_json = present stage fields "state" in
    let* state = as_object stage state_json in
    let* status = Result.map effect_status_of_wire (string_field stage state "status") in
    let* error = decode_effect_error stage state in
    Ok (Effect { session_id; turn_id; tool_name; status; error })
  | other -> Ok (Unrecognized_entry { kind = other; session_id; turn_id })
;;

let decode_entries text =
  let stage = "--output json" in
  let* json = parse stage text in
  decode_list stage "entries" decode_entry_json json
;;

let decode_streaming_line line =
  let* json = parse "--output streaming" line in
  decode_entry_json json
;;
