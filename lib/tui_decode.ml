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
  status : Masc_domain.task_status;
  priority : int;
}

type keeper = {
  k_name : string;
  k_trace_id : string;
  k_generation : int;
  k_paused : bool;
  k_current_task_id : string option;
  k_total_turns : int;
  k_total_tokens : int;
  k_total_cost_usd : float;
  k_last_turn_ts : string;
  k_compaction_count : int;
  k_autonomous_turn_count : int;
  k_autonomous_text_turn_count : int;
  k_autonomous_tool_turn_count : int;
  k_board_reactive_turn_count : int;
  k_mention_reactive_turn_count : int;
  k_noop_turn_count : int;
  k_last_proactive_outcome : string;
  k_last_blocker : string option;
  k_created_at : string;
  k_updated_at : string;
}

type planning_goal = {
  pg_id : string;
  pg_title : string;
  pg_phase : Goal_phase.t;
  pg_priority : int;
  pg_due_date : string option;
  pg_metric : string option;
  pg_target_value : string option;
}

type planning_rollup = {
  pr_active : int;
  pr_paused : int;
  pr_verifying : int;
  pr_done : int;
  pr_dropped : int;
}

type planning_backlog = {
  pb_todo : int;
  pb_claimed : int;
  pb_running : int;
  pb_done : int;
  pb_cancelled : int;
}

type planning_snapshot = {
  pl_goals : planning_goal list;
  pl_rollup : planning_rollup;
  pl_backlog : planning_backlog;
  pl_generated_at : string;
}

type log_kind =
  | Log_turn
  | Log_heartbeat

type log_channel =
  | Log_channel_turn
  | Log_channel_scheduled_autonomous
  | Log_channel_heartbeat

type log_entry = {
  le_kind : log_kind;
  le_ts : string;
  le_channel : log_channel;
  le_message_count : int option;
  le_input_tokens : int option;
  le_output_tokens : int option;
  le_latency_ms : int option;
  le_cost_usd : float option;
  le_work_kind : string option;
  le_tools_used : string list;
}

type context_unavailable_reason =
  | Context_measurement_missing
  | Context_turn_record_undecodable
  | Context_turn_record_read_failed
  | Context_turn_record_without_usage
  | Context_turn_record_trace_mismatch

type context_observation =
  | Context_observed of {
      ratio : float option;
      tokens : int;
      maximum : int option;
      observed_at : string;
      turn_ref : string;
    }
  | Context_unavailable of context_unavailable_reason

let ( let* ) = Result.bind

let member key json =
  match Json_util.assoc_member_opt key json with
  | Some v -> v
  | None -> `Null

let required_member json key =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "missing required field '%s'" key)

let optional_string json key =
  match member key json with
  | `Null -> Ok None
  | `String s -> Ok (Some s)
  | other ->
      Error
        (Printf.sprintf "field '%s' must be a string (received %s)" key
           (Json_util.kind_name other))

let required_nullable_int_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Int n) -> Ok (Some n)
  | Some (`Intlit s) -> (
      match int_of_string_opt s with
      | Some n -> Ok (Some n)
      | None ->
          Error (Printf.sprintf "field '%s' has non-integer intlit %S" key s))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be an int or null (received %s)" key
           (Json_util.kind_name other))

let required_nullable_float_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be a float or null (received %s)" key
           (Json_util.kind_name other))

let require_null_field json key =
  match Json_util.assoc_member_opt key json with
  | None -> Error (Printf.sprintf "missing required field '%s'" key)
  | Some `Null -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "field '%s' must be null (received %s)" key
           (Json_util.kind_name other))

let require_string_field json key = require_string json key
let require_int_field json key = require_int json key
let require_float_field json key = require_float json key
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

let task_of_domain (task : Masc_domain.task) =
  {
    id = task.id;
    title = task.title;
    status = task.task_status;
    priority = task.priority;
  }

let active_tasks_of_domain tasks =
  tasks
  |> List.map task_of_domain
  |> List.filter (fun task ->
       not (Masc_domain.task_status_is_terminal task.status))
  |> List.stable_sort (fun left right ->
       Int.compare left.priority right.priority)

let decode_task json =
  let* task = Masc_domain.task_of_yojson json in
  Ok (task_of_domain task)

let blocker_summary (blocker : Keeper_meta_contract.blocker_info) =
  let label = Keeper_meta_contract.blocker_class_to_string blocker.klass in
  match String.trim blocker.detail with
  | "" -> label
  | detail -> label ^ ": " ^ detail

let sanitize_terminal_text text =
  let escaped_byte byte = Printf.sprintf "\\x%02X" byte in
  let escaped_codepoint byte = Printf.sprintf "\\u00%02X" byte in
  let output = Buffer.create (String.length text) in
  let byte_at index = Char.code text.[index] in
  let is_continuation byte = byte >= 0x80 && byte <= 0xBF in
  let valid_utf8_length index =
    let remaining = String.length text - index in
    let first = byte_at index in
    if first >= 0xC2 && first <= 0xDF && remaining >= 2
       && is_continuation (byte_at (index + 1))
    then Some 2
    else if first = 0xE0 && remaining >= 3
            && byte_at (index + 1) >= 0xA0
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xE1 && first <= 0xEC && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xED && remaining >= 3
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x9F
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first >= 0xEE && first <= 0xEF && remaining >= 3
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
    then Some 3
    else if first = 0xF0 && remaining >= 4
            && byte_at (index + 1) >= 0x90
            && byte_at (index + 1) <= 0xBF
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first >= 0xF1 && first <= 0xF3 && remaining >= 4
            && is_continuation (byte_at (index + 1))
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else if first = 0xF4 && remaining >= 4
            && byte_at (index + 1) >= 0x80
            && byte_at (index + 1) <= 0x8F
            && is_continuation (byte_at (index + 2))
            && is_continuation (byte_at (index + 3))
    then Some 4
    else None
  in
  let rec append index =
    if index < String.length text
    then (
      let byte = Char.code text.[index] in
      if
        byte = 0xC2
        && index + 1 < String.length text
        && let next = Char.code text.[index + 1] in
           next >= 0x80 && next <= 0x9F
      then (
        Buffer.add_string output (escaped_codepoint (Char.code text.[index + 1]));
        append (index + 2))
      else if byte >= 0xC2
      then (
        match valid_utf8_length index with
        | Some length ->
          Buffer.add_substring output text index length;
          append (index + length)
        | None ->
          Buffer.add_char output text.[index];
          append (index + 1))
      else if byte < 0x20 || (byte >= 0x7F && byte <= 0x9F)
      then (
        Buffer.add_string output (escaped_byte byte);
        append (index + 1))
      else (
        Buffer.add_char output text.[index];
        append (index + 1)))
  in
  append 0;
  Buffer.contents output
;;

let keeper_blocker_for_terminal keeper =
  match keeper.k_last_blocker with
  | None -> "-"
  | Some blocker -> sanitize_terminal_text blocker
;;

let keeper_of_meta (meta : Keeper_meta_contract.keeper_meta) =
  let runtime = meta.runtime in
  let usage = runtime.usage in
  let compaction = runtime.compaction_rt in
  let proactive = runtime.proactive_rt in
  let k_last_turn_ts =
    if Float.compare usage.last_turn_ts 0.0 <= 0 then ""
    else Masc_domain.iso8601_of_unix_seconds usage.last_turn_ts
  in
  {
    k_name = meta.name;
    k_trace_id = Keeper_id.Trace_id.to_string runtime.trace_id;
    k_generation = runtime.nonce;
    k_paused = meta.paused;
    k_current_task_id =
      Option.map Keeper_id.Task_id.to_string meta.current_task_id;
    k_total_turns = usage.total_turns;
    k_total_tokens = usage.total_tokens;
    k_total_cost_usd = usage.total_cost_usd;
    k_last_turn_ts;
    k_compaction_count = compaction.count;
    k_autonomous_turn_count = runtime.autonomous_turn_count;
    k_autonomous_text_turn_count = runtime.autonomous_text_turn_count;
    k_autonomous_tool_turn_count = runtime.autonomous_tool_turn_count;
    k_board_reactive_turn_count = runtime.board_reactive_turn_count;
    k_mention_reactive_turn_count = runtime.mention_reactive_turn_count;
    k_noop_turn_count = runtime.noop_turn_count;
    k_last_proactive_outcome =
      Keeper_meta_contract.proactive_cycle_outcome_to_string
        proactive.last_outcome;
    k_last_blocker = Option.map blocker_summary runtime.last_blocker;
    k_created_at = meta.created_at;
    k_updated_at = meta.updated_at;
  }

let decode_keeper json =
  let* meta = Keeper_meta_json_parse.meta_of_json json in
  Ok (keeper_of_meta meta)

let decode_turn_channel raw =
  match Keeper_world_observation.channel_of_string raw with
  | Some Keeper_world_observation.Reactive -> Ok Log_channel_turn
  | Some Keeper_world_observation.Scheduled_autonomous ->
      Ok Log_channel_scheduled_autonomous
  | None -> Error (Printf.sprintf "unknown current turn channel %S" raw)

let decode_turn_mode json =
  let* raw = require_string_field json "turn_mode" in
  match Turn_mode_codec.turn_mode_of_string raw with
  | Some mode -> Ok mode
  | None -> Error (Printf.sprintf "unknown current turn mode %S" raw)

let validate_usage_projection ~input_tokens ~output_tokens
    ~cache_creation_tokens ~cache_read_tokens ~total_tokens ~cost_usd
    ~inner_trust ~inner_anomaly ~inner_reasons ~outer_trust ~outer_reasons =
  let classified =
    match
      ( input_tokens,
        output_tokens,
        cache_creation_tokens,
        cache_read_tokens,
        total_tokens,
        cost_usd )
    with
    | ( Some input_tokens,
        Some output_tokens,
        Some cache_creation_tokens,
        Some cache_read_tokens,
        Some total_tokens,
        Some cost_usd ) ->
        if total_tokens <> input_tokens + output_tokens then
          Error "usage total_tokens does not equal input_tokens + output_tokens"
        else
          let usage : Agent_core.Types.api_usage =
            { input_tokens;
              output_tokens;
              cache_creation_input_tokens = cache_creation_tokens;
              cache_read_input_tokens = cache_read_tokens;
              cost_usd = Some cost_usd;
            }
          in
          Ok (Keeper_usage_trust.classify ~usage_reported:true ~usage)
    | None, None, None, None, None, None ->
        let usage : Agent_core.Types.api_usage =
          { input_tokens = 0;
            output_tokens = 0;
            cache_creation_input_tokens = 0;
            cache_read_input_tokens = 0;
            cost_usd = None;
          }
        in
        Ok (Keeper_usage_trust.classify ~usage_reported:false ~usage)
    | _ ->
        Error
          "usage tokens, cost, and trust must form one current atomic observation"
  in
  let* classified = classified in
  let expected_trust = Keeper_usage_trust.to_string classified in
  let expected_reasons = Keeper_usage_trust.reasons classified in
  let expected_anomaly =
    match classified with
    | Keeper_usage_trust.Usage_untrusted _ -> true
    | Keeper_usage_trust.Usage_missing | Keeper_usage_trust.Usage_trusted ->
        false
  in
  if
    not
      (String.equal inner_trust expected_trust
      && String.equal outer_trust expected_trust)
  then Error "usage trust does not match the current counter observation"
  else if inner_anomaly <> expected_anomaly then
    Error "usage anomaly flag does not match the current trust classification"
  else if inner_reasons <> expected_reasons || outer_reasons <> expected_reasons
  then Error "usage anomaly reasons do not match the current trust classification"
  else Ok ()

let decode_log_entry json =
  let* kind =
    match Keeper_metrics_record.kind_of_json json with
    | Some kind -> Ok kind
    | None -> Error "unknown current keeper metrics schema or record kind"
  in
  let* le_ts = require_string_field json "ts" in
  let* _ts_unix = require_float_field json "ts_unix" in
  let* raw_channel = require_string_field json "channel" in
  let* _name = require_string_field json "name" in
  let* _agent_name = require_string_field json "agent_name" in
  let* _trace_id = require_string_field json "trace_id" in
  let* _generation = require_int_field json "generation" in
  match kind with
  | Keeper_metrics_record.Heartbeat ->
      if not (String.equal raw_channel "heartbeat") then
        Error
          (Printf.sprintf "heartbeat metrics row has invalid channel %S"
             raw_channel)
      else
        let* le_message_count =
          required_nullable_int_field json "message_count"
        in
        let* () =
          if Option.exists (fun count -> count < 0) le_message_count then
            Error "heartbeat message_count must be non-negative"
          else Ok ()
        in
        Ok
          { le_kind = Log_heartbeat;
            le_ts;
            le_channel = Log_channel_heartbeat;
            le_message_count;
            le_input_tokens = None;
            le_output_tokens = None;
            le_latency_ms = None;
            le_cost_usd = None;
            le_work_kind = None;
            le_tools_used = [];
          }
  | Keeper_metrics_record.Turn ->
      let* le_channel = decode_turn_channel raw_channel in
      let* le_message_count = require_int_field json "message_count" in
      let* () =
        if le_message_count < 0 then
          Error "turn message_count must be non-negative"
        else Ok ()
      in
      let* usage =
        match member "usage" json with
        | `Assoc _ as usage -> Ok usage
        | `Null -> Error "missing required field 'usage'"
        | other ->
            Error
              (Printf.sprintf "field 'usage' must be an object (received %s)"
                 (Json_util.kind_name other))
      in
      let* le_input_tokens =
        required_nullable_int_field usage "input_tokens"
      in
      let* le_output_tokens =
        required_nullable_int_field usage "output_tokens"
      in
      let* cache_creation_tokens =
        required_nullable_int_field usage "cache_creation_tokens"
      in
      let* cache_read_tokens =
        required_nullable_int_field usage "cache_read_tokens"
      in
      let* total_tokens = required_nullable_int_field usage "total_tokens" in
      let* inner_usage_trust = require_string_field usage "usage_trust" in
      let* inner_usage_anomaly = require_bool usage "usage_anomaly" in
      let* inner_usage_anomaly_reasons =
        require_string_list usage "usage_anomaly_reasons"
      in
      let* outer_usage_trust = require_string_field json "usage_trust" in
      let* outer_usage_anomaly_reasons =
        require_string_list json "usage_anomaly_reasons"
      in
      let* latency_ms = require_int_field json "latency_ms" in
      let* () =
        if latency_ms < 0 then Error "latency_ms must be non-negative" else Ok ()
      in
      let* le_cost_usd = required_nullable_float_field json "cost_usd" in
      let* () =
        validate_usage_projection ~input_tokens:le_input_tokens
          ~output_tokens:le_output_tokens ~cache_creation_tokens
          ~cache_read_tokens ~total_tokens ~cost_usd:le_cost_usd
          ~inner_trust:inner_usage_trust
          ~inner_anomaly:inner_usage_anomaly
          ~inner_reasons:inner_usage_anomaly_reasons
          ~outer_trust:outer_usage_trust
          ~outer_reasons:outer_usage_anomaly_reasons
      in
      let* turn_mode = decode_turn_mode json in
      let* tool_call_count = require_int_field json "tool_call_count" in
      let* le_tools_used = require_string_list json "tools_used" in
      let* () =
        if tool_call_count < 0 then Error "tool_call_count must be non-negative"
        else if tool_call_count <> List.length le_tools_used then
          Error "tool_call_count does not match tools_used"
        else
          match turn_mode with
          | Turn_mode_codec.Tool_use -> Ok ()
          | Turn_mode_codec.Text_response
          | Turn_mode_codec.Skip_text
          | Turn_mode_codec.Noop ->
              if tool_call_count = 0 then Ok ()
              else Error "non-tool turn mode cannot carry tool calls"
      in
      Ok
        { le_kind = Log_turn;
          le_ts;
          le_channel;
          le_message_count = Some le_message_count;
          le_input_tokens;
          le_output_tokens;
          le_latency_ms = Some latency_ms;
          le_cost_usd;
          le_work_kind =
            Some (Turn_mode_codec.work_kind_of_turn_mode turn_mode);
          le_tools_used;
        }

let parse_log_entry line =
  let json =
    try Ok (Yojson.Safe.from_string line)
    with Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  in
  let* json = json in
  decode_log_entry json

let context_unavailable_reason_of_string = function
  | "context_measurement_missing" -> Ok Context_measurement_missing
  | "turn_record_undecodable" -> Ok Context_turn_record_undecodable
  | "turn_record_read_failed" -> Ok Context_turn_record_read_failed
  | "turn_record_without_usage" -> Ok Context_turn_record_without_usage
  | "turn_record_trace_mismatch" -> Ok Context_turn_record_trace_mismatch
  | raw -> Error (Printf.sprintf "unknown context unavailable reason %S" raw)

let context_unavailable_reason_to_string = function
  | Context_measurement_missing -> "context measurement missing"
  | Context_turn_record_undecodable -> "turn record undecodable"
  | Context_turn_record_read_failed -> "turn record read failed"
  | Context_turn_record_without_usage -> "turn record has no provider usage"
  | Context_turn_record_trace_mismatch -> "turn record belongs to a prior trace"

let require_object_member json key =
  let* value = required_member json key in
  match value with
  | `Assoc _ as object_value -> Ok object_value
  | other ->
      Error
        (Printf.sprintf "field '%s' must be an object (received %s)" key
           (Json_util.kind_name other))

let decode_context_unavailable_payload json =
  let* kind = require_string_field json "kind" in
  if not (String.equal kind "not_observed") then
    Error (Printf.sprintf "unknown context unavailable kind %S" kind)
  else
    let* reason = require_string_field json "reason" in
    context_unavailable_reason_of_string reason

let validate_context_ratio ~tokens ~maximum ~ratio =
  match maximum, ratio with
  | Some maximum, Some ratio when maximum > 0 ->
      let expected = Float.of_int tokens /. Float.of_int maximum in
      let tolerance = 1e-12 *. Float.max 1.0 (Float.abs expected) in
      if Float.is_finite ratio && Float.abs (ratio -. expected) <= tolerance then
        Ok ()
      else Error "context ratio does not match tokens / context window"
  | Some maximum, None when maximum > 0 ->
      Error "positive context window requires an observed ratio"
  | (None | Some 0), None -> Ok ()
  | (None | Some 0), Some _ ->
      Error "context ratio requires a positive context window"
  | Some _, (Some _ | None) -> Error "context window must be non-negative"

let decode_context_observation ~expected_trace_id json =
  match Json_util.assoc_member_opt "context_metrics_unavailable" json with
  | None -> Error "missing required field 'context_metrics_unavailable'"
  | Some (`Assoc _ as unavailable) ->
      let* reason = decode_context_unavailable_payload unavailable in
      let* () = require_null_field json "context_ratio" in
      let* () = require_null_field json "context_tokens" in
      let* () = require_null_field json "context_max" in
      let* () = require_null_field json "context_source" in
      let* context = require_object_member json "context" in
      let* () = require_null_field context "source" in
      let* () = require_null_field context "context_ratio" in
      let* () = require_null_field context "context_tokens" in
      let* () = require_null_field context "context_max" in
      let* nested_unavailable =
        require_object_member context "metrics_unavailable"
      in
      let* nested_reason =
        decode_context_unavailable_payload nested_unavailable
      in
      if nested_reason <> reason then
        Error "nested and top-level context unavailable reasons disagree"
      else Ok (Context_unavailable reason)
  | Some `Null ->
      let* ratio = required_nullable_float_field json "context_ratio" in
      let* tokens = require_int_field json "context_tokens" in
      let* maximum = required_nullable_int_field json "context_max" in
      let* source = require_string_field json "context_source" in
      if not (String.equal source "turn_record") then
        Error (Printf.sprintf "unknown context observation source %S" source)
      else if
        tokens < 0
        || Option.exists (fun value -> not (Float.is_finite value)) ratio
      then
        Error "context observation has an invalid numeric range"
      else
        let* () = validate_context_ratio ~tokens ~maximum ~ratio in
        let* context = require_object_member json "context" in
        let* nested_source = require_string_field context "source" in
        let* nested_ratio =
          required_nullable_float_field context "context_ratio"
        in
        let* nested_tokens = require_int_field context "context_tokens" in
        let* nested_maximum =
          required_nullable_int_field context "context_max"
        in
        let* () = require_null_field context "metrics_unavailable" in
        if not (String.equal nested_source source) then
          Error "nested and top-level context sources disagree"
        else if
          nested_ratio <> ratio || nested_tokens <> tokens
          || nested_maximum <> maximum
        then Error "nested and top-level context measurements disagree"
        else
          let* observed_at = require_string_field context "observed_at" in
          let* turn_ref_json = required_member context "turn_ref" in
          let* turn_ref = Ids.Turn_ref.of_yojson turn_ref_json in
          let* absolute_turn = require_int_field context "absolute_turn" in
          let* request_body_bytes =
            required_nullable_int_field context "request_body_bytes"
          in
          if
            not
              (String.equal (Ids.Turn_ref.trace_id turn_ref) expected_trace_id)
          then Error "context turn reference belongs to a different trace"
          else if absolute_turn <> Ids.Turn_ref.absolute_turn turn_ref then
            Error "context absolute turn disagrees with its turn reference"
          else if Option.exists (fun value -> value < 0) request_body_bytes then
            Error "context request body bytes must be non-negative"
          else
            Ok
              (Context_observed
                 { ratio;
                   tokens;
                   maximum;
                   observed_at;
                   turn_ref = Ids.Turn_ref.to_string turn_ref;
                 })
  | Some other ->
      Error
        (Printf.sprintf
           "field 'context_metrics_unavailable' must be an object or null (received %s)"
           (Json_util.kind_name other))

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

let is_success_http_status status_code = status_code >= 200 && status_code < 300

let http_status_error ~status_code ~body =
  let body = String.trim body in
  let detail =
    if body = "" then "empty response body"
    else if String.length body > 240 then String.sub body 0 240 ^ "..."
    else body
  in
  Printf.sprintf "HTTP %d: %s" status_code detail

let decode_json_response_body ~allow_empty ~status_code ~body :
    (Yojson.Safe.t, string) result =
  if not (is_success_http_status status_code) then
    Error (http_status_error ~status_code ~body)
  else if String.length (String.trim body) = 0 then
    if allow_empty then Ok (`Assoc []) else Error "empty response body"
  else
    try Ok (Yojson.Safe.from_string body)
    with Yojson.Json_error e -> Error (Printf.sprintf "(JSON parse: %s)" e)

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

let decode_planning_goal json =
  let* pg_id = required_string_field json "id" in
  let* pg_title = required_string_field json "title" in
  let* raw_phase = required_string_field json "phase" in
  let* pg_phase =
    match Goal_phase.parse raw_phase with
    | Some phase -> Ok phase
    | None -> Error (Printf.sprintf "unknown planning goal phase %S" raw_phase)
  in
  let* pg_priority = required_int_field json "priority" in
  let* pg_due_date = optional_string_field json "due_date" in
  let* pg_metric = optional_string_field json "metric" in
  let* pg_target_value = optional_string_field json "target_value" in
  Ok
    {
      pg_id;
      pg_title;
      pg_phase;
      pg_priority;
      pg_due_date;
      pg_metric;
      pg_target_value;
    }

let decode_planning_rollup json =
  let* pr_active = required_int_field json "active_count" in
  let* pr_paused = required_int_field json "paused_count" in
  let* pr_verifying = required_int_field json "verifying_count" in
  let* pr_done = required_int_field json "done_count" in
  let* pr_dropped = required_int_field json "dropped_count" in
  Ok { pr_active; pr_paused; pr_verifying; pr_done; pr_dropped }

let decode_planning_backlog json =
  let* pb_todo = required_int_field json "todo" in
  let* pb_claimed = required_int_field json "claimed" in
  let* pb_running = required_int_field json "in_progress" in
  let* pb_done = required_int_field json "done" in
  let* pb_cancelled = required_int_field json "cancelled" in
  Ok { pb_todo; pb_claimed; pb_running; pb_done; pb_cancelled }

let decode_planning_snapshot json =
  let* goals_json = required_list_field json "goals" in
  let* pl_goals = decode_list "goals" decode_planning_goal goals_json in
  let* rollup_json = required_object_field json "rollup" in
  let* pl_rollup = decode_planning_rollup rollup_json in
  let* backlog_json = required_object_field json "task_backlog" in
  let* pl_backlog = decode_planning_backlog backlog_json in
  let* pl_generated_at = required_string_field json "generated_at" in
  Ok { pl_goals; pl_rollup; pl_backlog; pl_generated_at }

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
