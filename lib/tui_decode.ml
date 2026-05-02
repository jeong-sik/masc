open Json_util

type agent = {
  name : string;
  status : string;
  current_task : string option;
  last_seen : string;
}

type task = {
  id : string;
  title : string;
  status : string;
  priority : int;
  claimed_by : string option;
  parent_task_id : string option;
  goal_id : string option;
}

type keeper = {
  k_name : string;
  k_goal : string;
  k_short_goal : string;
  k_generation : int;
  k_active_model : string option;
  k_models : string list;
  k_proactive_enabled : bool;
  k_initiative_enabled : bool option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_compaction_ratio_gate : float;
  k_trigger_mode : string;
  k_context_budget : int;
  k_handoff_threshold : float;
  k_drift_enabled : bool;
  k_verify : bool;
  k_created_at : string;
  k_updated_at : string;
}

type log_entry = {
  le_ts : string;
  le_channel : string;
  le_context_ratio : float;
  le_context_tokens : int;
  le_context_max : int;
  le_message_count : int;
  le_model_used : string option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
  le_compacted : bool option;
  le_goal_alignment : float option;
  le_repetition_risk : float option;
  le_guardrail_stop : bool option;
}

let ( let* ) = Result.bind

let member key json = Yojson.Safe.Util.member key json

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | _ -> Error (Printf.sprintf "field '%s' must be a string" key)

let optional_int json key =
  match member key json with
  | `Null -> Ok None
  | `Int n -> Ok (Some n)
  | `Intlit s -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | _ -> Error (Printf.sprintf "field '%s' must be an int" key)

let optional_float json key =
  match member key json with
  | `Null -> Ok None
  | `Float f -> Ok (Some f)
  | `Int n -> Ok (Some (Float.of_int n))
  | _ -> Error (Printf.sprintf "field '%s' must be a float" key)

let optional_bool json key =
  match member key json with
  | `Null -> Ok None
  | `Bool b -> Ok (Some b)
  | _ -> Error (Printf.sprintf "field '%s' must be a bool" key)

let require_string_field json key = require_string json key
let require_int_field json key = require_int json key
let require_float_field json key = require_float json key
let require_bool_field json key = require_bool json key

let require_string_list json key =
  match member key json with
  | `List items ->
      List.mapi
        (fun idx item ->
          match item with
          | `String value -> Ok value
          | _ ->
              Error
                (Printf.sprintf "field '%s[%d]' must be a string" key idx))
        items
      |> List.fold_left
           (fun acc item ->
             let* parsed = acc in
             let* value = item in
             Ok (value :: parsed))
           (Ok [])
      |> Result.map List.rev
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | _ -> Error (Printf.sprintf "field '%s' must be an array" key)

let string_of_intlike_float_field key f =
  if not (Float.is_finite f) then
    Error (Printf.sprintf "field '%s' must be a finite number" key)
  else
    try Ok (string_of_int (int_of_float f))
    with Invalid_argument _ ->
      Error (Printf.sprintf "field '%s' is out of range for int" key)

let decode_status json =
  match member "status" json with
  | `String s -> Ok s
  | `List (`String s :: _) -> Ok s
  | `List [] -> Error "field 'status' list must not be empty"
  | `Null -> Error "missing required field 'status'"
  | _ -> Error "field 'status' must be a string or non-empty string array"

let decode_agent json =
  let* name = require_string_field json "name" in
  let* status = decode_status json in
  let* current_task = optional_string json "current_task" in
  let* last_seen = require_string_field json "last_seen" in
  Ok { name; status; current_task; last_seen }

let decode_task json =
  let* id = require_string_field json "id" in
  let* title = require_string_field json "title" in
  let* status = require_string_field json "status" in
  let* priority = optional_int json "priority" in
  let* claimed_by = optional_string json "claimed_by" in
  let* parent_task_id = optional_string json "parent_task_id" in
  let* goal_id = optional_string json "goal_id" in
  Ok
    {
      id;
      title;
      status;
      priority = Option.value priority ~default:3;
      claimed_by;
      parent_task_id;
      goal_id;
    }

let decode_keeper ~filename json =
  let* k_goal = require_string_field json "goal" in
  let* k_short_goal = require_string_field json "short_goal" in
  
  let* k_generation = require_int_field json "generation" in
  let* k_active_model = optional_string json "active_model" in
  let* k_models =
    match member "models" json with
    | `Null -> Ok []
    | `List _ -> require_string_list json "models"
    | _ -> Error "field 'models' must be a list of strings"
  in
  let* k_proactive_enabled = require_bool_field json "proactive_enabled" in
  let* k_initiative_enabled = optional_bool json "initiative_enabled" in
  let* k_total_turns = require_int_field json "total_turns" in
  let* k_total_tokens = require_int_field json "total_tokens" in
  let* k_total_cost_usd = require_float_field json "total_cost_usd" in
  let* k_last_turn_ts =
    match member "last_turn_ts" json with
    | `String s -> Ok s
    | `Float f -> string_of_intlike_float_field "last_turn_ts" f
    | `Int n -> Ok (string_of_int n)
    | `Null -> Ok ""
    | _ -> Error "field 'last_turn_ts' must be a string, number, or null"
  in
  let* k_compaction_count = require_int_field json "compaction_count" in
  let* k_compaction_ratio_gate = require_float_field json "compaction_ratio_gate" in
  let* k_trigger_mode = require_string_field json "trigger_mode" in
  let* k_context_budget = require_int_field json "context_budget" in
  let* k_handoff_threshold = require_float_field json "handoff_threshold" in
  let* k_drift_enabled = require_bool_field json "drift_enabled" in
  let* k_verify = require_bool_field json "verify" in
  let* k_created_at = require_string_field json "created_at" in
  let* k_updated_at = require_string_field json "updated_at" in
  let default_name =
    if Filename.check_suffix filename ".json" then
      Filename.chop_suffix filename ".json"
    else
      Filename.remove_extension filename
  in
  let k_name = Option.value (get_string json "name") ~default:default_name in
  Ok
    {
      k_name;
      k_goal;
      k_short_goal;
      k_generation;
      k_active_model;
      k_models;
      k_proactive_enabled;
      k_initiative_enabled;
      k_total_turns;
      k_total_tokens;
      k_total_cost_usd;
      k_last_turn_ts;
      k_compaction_count;
      k_compaction_ratio_gate;
      k_trigger_mode;
      k_context_budget;
      k_handoff_threshold;
      k_drift_enabled;
      k_verify;
      k_created_at;
      k_updated_at;
    }

let parse_log_entry line =
  let json =
    try Ok (Yojson.Safe.from_string line)
    with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  let* json = json in
  let* le_ts = require_string_field json "ts" in
  let* le_channel = require_string_field json "channel" in
  let* le_context_ratio = require_float_field json "context_ratio" in
  let* le_context_tokens = require_int_field json "context_tokens" in
  let* le_context_max = require_int_field json "context_max" in
  let* le_message_count = require_int_field json "message_count" in
  let le_model_used = get_string json "model_used" in
  let usage_json = get_object json "usage" in
  let* le_input_tokens =
    match usage_json with
    | None -> Ok None
    | Some usage -> optional_int usage "input_tokens"
  in
  let* le_output_tokens =
    match usage_json with
    | None -> Ok None
    | Some usage -> optional_int usage "output_tokens"
  in
  let* le_latency_ms = optional_int json "latency_ms" in
  let* le_cost_usd = optional_float json "cost_usd" in
  let* le_work_kind = optional_string json "work_kind" in
  let le_tools_used =
    match member "tools_used" json with
    | `Null -> Ok []
    | `List _ -> require_string_list json "tools_used"
    | _ -> Error "field 'tools_used' must be an array"
  in
  let* le_tools_used = le_tools_used in
  let* le_compacted = optional_bool json "compacted" in
  let* le_goal_alignment = optional_float json "goal_alignment" in
  let* le_repetition_risk = optional_float json "repetition_risk" in
  let* le_guardrail_stop = optional_bool json "guardrail_stop" in
  Ok
    {
      le_ts;
      le_channel;
      le_context_ratio;
      le_context_tokens;
      le_context_max;
      le_message_count;
      le_model_used;
      le_input_tokens;
      le_output_tokens;
      le_latency_ms;
      le_cost_usd;
      le_work_kind;
      le_tools_used;
      le_compacted;
      le_goal_alignment;
      le_repetition_risk;
      le_guardrail_stop;
    }

let trim = String.trim

let split_headers_body response =
  let marker = "\r\n\r\n" in
  let rec find idx =
    if idx + String.length marker > String.length response then None
    else if String.sub response idx (String.length marker) = marker then
      Some (idx + String.length marker)
    else
      find (idx + 1)
  in
  match find 0 with
  | Some idx -> Some (String.sub response idx (String.length response - idx))
  | None -> None

type chat_event =
  | Delta of string
  | Complete of string
  | Ignore

let decode_chat_event json =
  let event_type = get_string json "type" in
  match event_type with
  | Some ("content_delta" | "delta") -> (
      match get_string json "delta" with
      | Some text -> Ok (Delta text)
      | None -> Error "delta event missing string 'delta'")
  | Some ("content_complete" | "complete") -> (
      match get_string json "text" with
      | Some text -> Ok (Complete text)
      | None -> Ok Ignore)
  | _ -> (
      match get_object json "error" with
      | Some err_json -> (
          match get_string err_json "message" with
          | Some message -> Error message
          | None -> Error "error payload missing string 'message'")
      | None -> Ok Ignore)

let parse_keeper_chat_response response =
  let lines = String.split_on_char '\n' response in
  let result = Buffer.create 256 in
  let completion_text = ref None in
  let rec consume_sse = function
    | [] -> Ok ()
    | raw_line :: rest ->
        let line = trim raw_line in
        if String.length line > 6 && Base.String.is_prefix line ~prefix:"data: " then (
          let payload = String.sub line 6 (String.length line - 6) |> trim in
          if payload = "[DONE]" || payload = "" then consume_sse rest
          else
            let* json =
              try Ok (Yojson.Safe.from_string payload)
              with Yojson.Json_error msg ->
                Error ("invalid SSE JSON payload: " ^ msg)
            in
            let* chunk = decode_chat_event json in
            (match chunk with
             | Delta text -> Buffer.add_string result text
             | Complete text when Buffer.length result = 0 -> completion_text := Some text
             | Complete _ -> ()
             | Ignore -> ());
            consume_sse rest
        ) else
          consume_sse rest
  in
  let* () = consume_sse lines in
  if Buffer.length result > 0 then
    Ok (Buffer.contents result)
  else
    match !completion_text with
    | Some text when text <> "" -> Ok text
    | _ -> (
        match split_headers_body response with
        | None -> Error "empty response body"
        | Some body ->
            let* json =
              try Ok (Yojson.Safe.from_string (trim body))
              with Yojson.Json_error msg ->
                Error ("invalid response JSON: " ^ msg)
            in
            match get_object json "result" with
            | Some result_json -> (
                match get_string result_json "text" with
                | Some text when text <> "" -> Ok text
                | _ -> Error "response JSON missing result.text")
            | None -> (
                match get_object json "error" with
                | Some err_json -> (
                    match get_string err_json "message" with
                    | Some message -> Error message
                    | None -> Error "response JSON missing error.message")
                | None -> Error "response JSON missing result"))
