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
}

type keeper = {
  k_name : string;
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
}

let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a string (received %s)" key
           (Json_util.kind_name other))

let optional_int json key =
  match member key json with
  | `Null -> Ok None
  | `Int n -> Ok (Some n)
  | `Intlit s -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an int (received %s)" key
           (Json_util.kind_name other))

let optional_float json key =
  match member key json with
  | `Null -> Ok None
  | `Float f -> Ok (Some f)
  | `Int n -> Ok (Some (Float.of_int n))
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a float (received %s)" key
           (Json_util.kind_name other))

let optional_bool json key =
  match member key json with
  | `Null -> Ok None
  | `Bool b -> Ok (Some b)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a bool (received %s)" key
           (Json_util.kind_name other))

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
          | bad ->
              Error
                (Printf.sprintf
                   "field '%s[%d]' must be a string (received %s)" key idx
                   (Json_util.kind_name bad)))
        items
      |> List.fold_left
           (fun acc item ->
             let* parsed = acc in
             let* value = item in
             Ok (value :: parsed))
           (Ok [])
      |> Result.map List.rev
  | `Null -> Error (Printf.sprintf "missing required field '%s'" key)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an array (received %s)" key
           (Json_util.kind_name other))

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
  | `List (bad :: _) ->
      Error
        (Printf.sprintf
           "field 'status' list head must be a string (received %s)"
           (Json_util.kind_name bad))
  | `Null -> Error "missing required field 'status'"
  | other ->
      Error
        (Printf.sprintf
           "field 'status' must be a string or non-empty string array \
            (received %s)"
           (Json_util.kind_name other))

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
  Ok
    {
      id;
      title;
      status;
      priority = Option.value priority ~default:3;
      claimed_by;
      parent_task_id;
    }

let decode_keeper ~filename json =
  let* k_generation = require_int_field json "generation" in
  let* k_active_model = optional_string json "active_model" in
  let* k_models =
    match member "models" json with
    | `Null -> Ok []
    | `List _ -> require_string_list json "models"
    | other ->
        Error
          (Printf.sprintf
             "field 'models' must be a list of strings (received %s)"
             (Json_util.kind_name other))
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
    | other ->
        Error
          (Printf.sprintf
             "field 'last_turn_ts' must be a string, number, or null \
              (received %s)"
             (Json_util.kind_name other))
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
    | other ->
        Error
          (Printf.sprintf
             "field 'tools_used' must be an array (received %s)"
             (Json_util.kind_name other))
  in
  let* le_tools_used = le_tools_used in
  let* le_compacted = optional_bool json "compacted" in
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
    }

let trim = String.trim

type http_response = {
  status_code : int;
  body : string;
}

let parse_http_status_code (line : string) : (int, string) result =
  match String.split_on_char ' ' (String.trim line) |> List.filter (( <> ) "") with
  | version :: code :: _
    when String.length version >= 5 && String.starts_with ~prefix:"HTTP/" version
    -> (
      match int_of_string_opt code with
      | Some status -> Ok status
      | None -> Error (Printf.sprintf "invalid HTTP status code: %S" code))
  | _ -> Error (Printf.sprintf "invalid HTTP status line: %S" line)

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

let parse_http_response (response : string) : (http_response, string) result =
  match String.split_on_char '\n' response with
  | [] | [ "" ] -> Error "empty HTTP response"
  | status_line :: _ ->
      let* status_code = parse_http_status_code status_line in
      let* body =
        match split_headers_body response with
        | Some body -> Ok body
        | None -> Error "no empty line in HTTP response"
      in
      Ok { status_code; body }

let is_success_http_status status_code = status_code >= 200 && status_code < 300

let http_status_error response =
  let body = String.trim response.body in
  let detail =
    if body = "" then "empty response body"
    else if String.length body > 240 then String.sub body 0 240 ^ "..."
    else body
  in
  Printf.sprintf "HTTP %d: %s" response.status_code detail

let decode_json_response_body ~allow_empty ~status_code ~body :
    (Yojson.Safe.t, string) result =
  if not (is_success_http_status status_code) then
    Error (http_status_error { status_code; body })
  else if String.length (String.trim body) = 0 then
    if allow_empty then Ok (`Assoc []) else Error "empty response body"
  else
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error e -> Error (Printf.sprintf "(JSON parse: %s)" e)

let decode_json_http_response ~allow_empty (raw : string) :
    (Yojson.Safe.t, string) result =
  let* response = parse_http_response raw in
  decode_json_response_body ~allow_empty ~status_code:response.status_code
    ~body:response.body

let missing_field key =
  Error (Printf.sprintf "missing required field '%s'" key)

let field_type_error key expected value =
  Error
    (Printf.sprintf "field '%s' must be %s (received %s)" key expected
       (Json_util.kind_name value))

let required_string_field json key =
  match member key json with
  | `String value -> Ok value
  | `Null -> missing_field key
  | bad -> field_type_error key "a string" bad

let optional_string_field json key =
  match member key json with
  | `String value -> Ok (Some value)
  | `Null -> Ok None
  | bad -> field_type_error key "a string or null" bad

let required_int_field json key =
  match member key json with
  | `Int value -> Ok value
  | `Intlit raw -> (
      match int_of_string_opt raw with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "field '%s' has invalid int %S" key raw))
  | `Null -> missing_field key
  | bad -> field_type_error key "an int" bad

let required_int_any_field json keys =
  let rec loop = function
    | [] ->
        Error
          (Printf.sprintf "missing required field '%s'"
             (String.concat "' or '" keys))
    | key :: rest -> (
        match member key json with
        | `Null -> loop rest
        | _ -> required_int_field json key)
  in
  loop keys

let int_field_or json key ~default =
  match member key json with
  | `Null -> Ok default
  | _ -> required_int_field json key

let required_display_field json key =
  match member key json with
  | `String value -> Ok value
  | `Int value -> Ok (string_of_int value)
  | `Intlit value -> Ok value
  | `Float value -> Ok (Printf.sprintf "%.0f" value)
  | `Null -> missing_field key
  | bad -> field_type_error key "a scalar display value" bad

let required_display_any_field json keys =
  let rec loop = function
    | [] ->
        Error
          (Printf.sprintf "missing required field '%s'"
             (String.concat "' or '" keys))
    | key :: rest -> (
        match member key json with
        | `Null -> loop rest
        | _ -> required_display_field json key)
  in
  loop keys

let optional_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> (
      match member "content" json with
      | `String value -> Ok value
      | `Null -> Ok ""
      | bad -> field_type_error "content" "a string" bad)
  | bad -> field_type_error "body" "a string" bad

let required_body_field json =
  match member "body" json with
  | `String value -> Ok value
  | `Null -> required_string_field json "content"
  | bad -> field_type_error "body" "a string" bad

let required_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> missing_field key
  | bad -> field_type_error key "an array" bad

let optional_list_field json key =
  match member key json with
  | `List items -> Ok items
  | `Null -> Ok []
  | bad -> field_type_error key "an array" bad

let required_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok obj
  | `Null -> missing_field key
  | bad -> field_type_error key "an object" bad

let optional_object_field json key =
  match member key json with
  | `Assoc _ as obj -> Ok (Some obj)
  | `Null -> Ok None
  | bad -> field_type_error key "an object" bad

let decode_list label decode items =
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> (
        match decode item with
        | Ok decoded -> loop (idx + 1) (decoded :: acc) rest
        | Error err -> Error (Printf.sprintf "%s[%d]: %s" label idx err))
  in
  loop 0 [] items

let bounded_parent_depth ?(max_depth = 64) ~(id_of : 'a -> string)
    ~(parent_id_of : 'a -> string option) (items : 'a list) (item : 'a) : int =
  let module StringSet = Set.Make (String) in
  let rec loop seen depth current =
    if depth >= max_depth then depth
    else
      match parent_id_of current with
      | None -> depth
      | Some parent_id when StringSet.mem parent_id seen -> depth
      | Some parent_id -> (
          match List.find_opt (fun candidate -> id_of candidate = parent_id) items with
          | Some parent ->
              loop (StringSet.add parent_id seen) (depth + 1) parent
          | None -> depth)
  in
  loop (StringSet.singleton (id_of item)) 0 item

type chat_event =
  | Delta of string
  | Complete of string
  | Ignore

let decode_chat_event json =
  let event_type = get_string json "type" in
  match event_type with
  | Some ("TEXT_MESSAGE_CONTENT" | "content_delta" | "delta") -> (
      match get_string json "delta" with
      | Some text -> Ok (Delta text)
      | None -> Error "delta event missing string 'delta'")
  | Some ("RUN_FINISHED" | "content_complete" | "complete") -> (
      match get_string json "text" with
      | Some text -> Ok (Complete text)
      | None -> Ok (Complete ""))
  | Some "RUN_ERROR" -> (
      match get_string json "message" with
      | Some message -> Error message
      | None -> (
          match get_object json "error" with
          | Some err_json -> (
              match get_string err_json "message" with
              | Some message -> Error message
              | None -> Error "RUN_ERROR payload missing string 'message'")
          | None -> Error "RUN_ERROR payload missing string 'message'"))
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
  let saw_terminal = ref false in
  let rec consume_sse = function
    | [] -> Ok ()
    | raw_line :: rest ->
        let line = trim raw_line in
        if String.length line > 6 && String.starts_with line ~prefix:"data: " then (
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
             | Complete text when Buffer.length result = 0 ->
                 saw_terminal := true;
                 if text <> "" then completion_text := Some text
             | Complete _ -> saw_terminal := true
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
    | _ when !saw_terminal -> Ok ""
    | _ -> (
        let body =
          match split_headers_body response with
          | Some body -> body
          | None -> response
        in
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
