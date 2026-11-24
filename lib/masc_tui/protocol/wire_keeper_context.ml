open Json_decode_fields
open Wire_common

let ( let* ) = Result.bind

let keeper_turn_records_path ~keeper ?(limit = 50) ?turn_ref () =
  let base =
    Printf.sprintf "/api/v1/keepers/%s/turn-records" (percent_encode keeper)
  in
  match turn_ref with
  | Some tr when not (String.equal (String.trim tr) "") ->
      base ^ "?turn_ref=" ^ percent_encode (String.trim tr)
  | Some _ | None -> Printf.sprintf "%s?limit=%d" base (max 1 limit)

let keeper_provider_input_path ~keeper ~turn_ref =
  Printf.sprintf "/api/v1/keepers/%s/provider-input?turn_ref=%s"
    (percent_encode keeper) (percent_encode turn_ref)

let keeper_provider_input_part_path ~keeper ~turn_ref ~index =
  Printf.sprintf "/api/v1/keepers/%s/provider-input/part?turn_ref=%s&index=%d"
    (percent_encode keeper) (percent_encode turn_ref) (max 0 index)

let keeper_cache_outcome_path ~keeper ~turn_ref =
  Printf.sprintf "/api/v1/keepers/%s/cache-outcome?turn_ref=%s"
    (percent_encode keeper) (percent_encode turn_ref)

let keeper_next_request_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/next-request" (percent_encode keeper)

let keeper_turn_transcript_path ~keeper ~turn_ref =
  Printf.sprintf "/api/v1/keepers/%s/turn-transcript?turn_ref=%s"
    (percent_encode keeper) (percent_encode turn_ref)

let keeper_tool_stats_path ~keeper ?(window_hours = 24) () =
  Printf.sprintf "/api/v1/keepers/%s/tool-stats?window_hours=%d"
    (percent_encode keeper) (max 1 (min 168 window_hours))

let keeper_tool_calls_path ~keeper ?(limit = 50) ?execution_ids () =
  let base =
    Printf.sprintf "/api/v1/keepers/%s/tool-calls" (percent_encode keeper)
  in
  match execution_ids with
  | Some ids when ids <> [] ->
      let deduped =
        let rec loop seen acc = function
          | [] -> List.rev acc
          | id :: rest ->
              let s = String.trim id in
              if String.equal s "" || List.mem s seen then loop seen acc rest
              else loop (s :: seen) (s :: acc) rest
        in
        loop [] [] ids
      in
      if deduped = [] then Printf.sprintf "%s?limit=%d" base (max 1 (min 200 limit))
      else
        let encoded =
          Yojson.Safe.to_string (`List (List.map (fun s -> `String s) deduped))
        in
        base ^ "?execution_ids=" ^ percent_encode encoded
  | Some _ | None -> Printf.sprintf "%s?limit=%d" base (max 1 (min 200 limit))

let keeper_tool_result_path ~keeper ~execution_id ?offset ?max_bytes ?source_id
    () =
  let params =
    [ "execution_id=" ^ percent_encode execution_id ]
    @ (match offset with
       | Some n when n > 0 -> [ Printf.sprintf "offset=%d" n ]
       | Some _ | None -> [])
    @ (match max_bytes with
       | Some n when n > 0 -> [ Printf.sprintf "max_bytes=%d" n ]
       | Some _ | None -> [])
    @
    match source_id with
    | Some s when not (String.equal (String.trim s) "") ->
        [ "source_id=" ^ percent_encode (String.trim s) ]
    | Some _ | None -> []
  in
  Printf.sprintf "/api/v1/keepers/%s/tool-result?%s" (percent_encode keeper)
    (String.concat "&" params)

(* --- Turn Records --- *)

type turn_block_diff = {
  added : Turn_record.prompt_block list;
  removed : Turn_record.prompt_block list;
  changed : (Turn_record.prompt_block * Turn_record.prompt_block) list;
}

type turn_record_entry = {
  record : Turn_record.t;
  diff_vs_prev : turn_block_diff option;
}

type turn_records_page = {
  keeper : string;
  count : int;
  skipped_rows : int;
  health : string option;
  stale_reason : string option;
  live_turn_in_progress : bool;
  entries : turn_record_entry list;
}

let decode_prompt_block json =
  let* block_str = required_nonblank_string json "block" in
  let* block =
    match Prompt_block_id.of_string block_str with
    | Ok b -> Ok b
    | Error err -> Error ("unknown prompt block id (" ^ block_str ^ "): " ^ err)
  in
  let* bytes = required_nonnegative_int_field json "bytes" in
  let* digest = required_string_field json "digest" in
  Ok ({ Turn_record.block; bytes; digest } : Turn_record.prompt_block)

let decode_changed_pair json =
  let* prev_json = required_object_field json "prev" in
  let* next_json = required_object_field json "next" in
  let* prev_b = decode_prompt_block prev_json in
  let* next_b = decode_prompt_block next_json in
  Ok (prev_b, next_b)

let decode_block_diff json =
  match json with
  | `Null -> Ok None
  | `Assoc _ ->
      let* added_raw = optional_list_field json "added" in
      let* removed_raw = optional_list_field json "removed" in
      let* changed_raw = optional_list_field json "changed" in
      let* added = decode_list "added" decode_prompt_block added_raw in
      let* removed = decode_list "removed" decode_prompt_block removed_raw in
      let* changed = decode_list "changed" decode_changed_pair changed_raw in
      Ok (Some { added; removed; changed })
  | bad -> field_type_error "diff_vs_prev" "an object or null" bad

let decode_turn_record_entry json =
  let* rec_json = required_object_field json "record" in
  let* record = Turn_record.of_json rec_json in
  let* diff_vs_prev =
    if has_field json "diff_vs_prev" then
      decode_block_diff (member "diff_vs_prev" json)
    else Ok None
  in
  Ok { record; diff_vs_prev }

let decode_turn_records json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* skipped_opt = optional_int_field body "skipped_rows" in
  let skipped_rows = Option.value ~default:0 skipped_opt in
  let* health = optional_nonblank_string body "health" in
  let* stale_reason = optional_nonblank_string body "stale_reason" in
  let* live_opt = optional_bool_field body "live_turn_in_progress" in
  let live_turn_in_progress = Option.value ~default:false live_opt in
  let* raw_entries = required_list_field body "entries" in
  let* entries_oldest_first =
    decode_list "entries" decode_turn_record_entry raw_entries
  in
  let entries =
    List.sort
      (fun (a : turn_record_entry) (b : turn_record_entry) ->
        match Float.compare b.record.ts a.record.ts with
        | 0 -> Int.compare b.record.absolute_turn a.record.absolute_turn
        | c -> c)
      entries_oldest_first
  in
  let* count_opt = optional_int_field body "count" in
  let count = Option.value ~default:(List.length entries) count_opt in
  Ok
    {
      keeper;
      count;
      skipped_rows;
      health;
      stale_reason;
      live_turn_in_progress;
      entries;
    }

(* --- Provider Input Manifest & Part --- *)

type provider_part_kind =
  | Part_system_prompt
  | Part_message of { role : string }
  | Part_tool_schema of { name : string }

type provider_input_part = {
  part_index : int;
  part_kind : provider_part_kind;
  part_bytes : int;
  part_sha256 : string;
}

type provider_input_manifest = {
  keeper : string;
  trace_id : string;
  absolute_turn : int;
  turn_ref : string;
  runtime_profile : string;
  captured_at_unix : float;
  wire_body_bytes : int option;
  wire_endpoint : string option;
  wire_phase : string option;
  wire_capture_id : string option;
  wire_provider : string option;
  wire_model : string option;
  wire_http_codec : string option;
  wire_stream : bool option;
  wire_body_sha256 : string option;
  parts : provider_input_part list;
}

type provider_input_part_content = {
  keeper : string;
  turn_ref : string;
  part : provider_input_part;
  text : string;
}

let decode_provider_part json =
  let* part_index = required_nonnegative_int_field json "index" in
  let* kind = required_nonblank_string json "kind" in
  let* part_kind =
    match kind with
    | "system_prompt" -> Ok Part_system_prompt
    | "message" ->
        let* role = required_nonblank_string json "role" in
        Ok (Part_message { role })
    | "tool_schema" ->
        let* name = required_nonblank_string json "name" in
        Ok (Part_tool_schema { name })
    | other -> Error ("unknown provider-input part kind: " ^ other)
  in
  let* part_bytes = required_nonnegative_int_field json "bytes" in
  let* part_sha256 = required_nonblank_string json "sha256" in
  Ok { part_index; part_kind; part_bytes; part_sha256 }

let decode_provider_input_manifest json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* trace_id = required_nonblank_string body "trace_id" in
  let* absolute_turn = required_nonnegative_int_field body "absolute_turn" in
  let* turn_ref = required_nonblank_string body "turn_ref" in
  let* runtime_profile = required_nonblank_string body "runtime_profile" in
  let* captured_at_unix = required_finite_float body "captured_at" in
  let* wire_opt = optional_object_field body "wire" in
  let* ( wire_body_bytes,
         wire_endpoint,
         wire_phase,
         wire_capture_id,
         wire_provider,
         wire_model,
         wire_http_codec,
         wire_stream,
         wire_body_sha256 ) =
    match wire_opt with
    | None -> Ok (None, None, None, None, None, None, None, None, None)
    | Some w ->
        let* bb = optional_int_field w "body_bytes" in
        let* ep = optional_nonblank_string w "endpoint" in
        let* phase = optional_nonblank_string w "phase" in
        let* capture_id = optional_nonblank_string w "capture_id" in
        let* provider = optional_nonblank_string w "provider" in
        let* model = optional_nonblank_string w "model" in
        let* http_codec = optional_nonblank_string w "http_codec" in
        let* stream = optional_bool_field w "stream" in
        let* body_sha256 = optional_nonblank_string w "body_sha256" in
        Ok
          ( bb,
            ep,
            phase,
            capture_id,
            provider,
            model,
            http_codec,
            stream,
            body_sha256 )
  in
  let* raw_parts = required_list_field body "parts" in
  let* parts = decode_list "parts" decode_provider_part raw_parts in
  Ok
    {
      keeper;
      trace_id;
      absolute_turn;
      turn_ref;
      runtime_profile;
      captured_at_unix;
      wire_body_bytes;
      wire_endpoint;
      wire_phase;
      wire_capture_id;
      wire_provider;
      wire_model;
      wire_http_codec;
      wire_stream;
      wire_body_sha256;
      parts;
    }

let decode_provider_input_part json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* turn_ref = required_nonblank_string body "turn_ref" in
  let* part_json = required_object_field body "part" in
  let* part = decode_provider_part part_json in
  let* text = required_string_field body "text" in
  Ok { keeper; turn_ref; part; text }

(* --- Cache Outcome --- *)

let decode_cache_outcome json =
  let* _, body = unwrap_v2_or_raw json in
  Keeper_cache_outcome_reading.of_json body

(* --- Next-Request Forecast --- *)

type forecast_rest =
  | Forecast_serving
  | Forecast_resting of { release_at_unix : float; release_basis : string }

type forecast_place = {
  walks_at : int;
  declared_at : int option;
  rest : forecast_rest;
}

type forecast_lane =
  | Forecast_agent_core
  | Forecast_not_applicable of string

type forecast_measured_parts = {
  reserved_measured_on_turn : int;
  reserved_bytes : int;
  instructions_bytes : int;
  schemas_bytes : int;
  pinned_measured_on_turn : int;
  pinned_measured_on_runtime : string;
  pinned_bytes : int;
  pinned_blocks : (string * int) list;
}

type forecast_parts =
  | Forecast_parts_ok of forecast_measured_parts
  | Forecast_parts_error of string

type forecast_carried = {
  first_atom : int;
  kept_atoms : int;
  transmitted_bytes : int;
  preamble_bytes : int option;
  origin_label : string;
  counted_tokens : int option;
}

type forecast_slot =
  | Slot_system_prompt of { bytes : int }
  | Slot_tools of { bytes : int }
  | Slot_preamble of { bytes : int }
  | Slot_history of { atoms : int; of_atoms : int; bytes : int }
  | Slot_wake_line of { bytes : int }
  | Slot_system_context of { bytes : int; blocks : (string * int) list }

type forecast_candidate = {
  runtime_id : string;
  lane : forecast_lane;
  parts : forecast_parts;
  history_atoms : int;
  carried : forecast_carried option;
  assembly : forecast_slot list option;
  place : forecast_place;
}

type forecast_walk =
  | Walk_order of { lane_id : string; declared : string list }
  | Walk_refused of string

type next_request_forecast = {
  keeper : string;
  trace_id : string;
  checkpoint_messages : int;
  wake_line_bytes : int;
  walk : forecast_walk;
  candidates : forecast_candidate list;
}

let decode_block_byte_pair json =
  let* blk = required_nonblank_string json "block" in
  let* bytes = required_nonnegative_int_field json "bytes" in
  Ok (blk, bytes)

let decode_forecast_slot json =
  let* slot = required_nonblank_string json "slot" in
  match slot with
  | "system_prompt" ->
      let* bytes = required_nonnegative_int_field json "bytes" in
      Ok (Slot_system_prompt { bytes })
  | "tools" ->
      let* bytes = required_nonnegative_int_field json "bytes" in
      Ok (Slot_tools { bytes })
  | "preamble" ->
      let* bytes = required_nonnegative_int_field json "bytes" in
      Ok (Slot_preamble { bytes })
  | "history" ->
      let* atoms = required_nonnegative_int_field json "atoms" in
      let* of_atoms = required_nonnegative_int_field json "of_atoms" in
      let* bytes = required_nonnegative_int_field json "bytes" in
      Ok (Slot_history { atoms; of_atoms; bytes })
  | "wake_line" ->
      let* bytes = required_nonnegative_int_field json "bytes" in
      Ok (Slot_wake_line { bytes })
  | "system_context" ->
      let* bytes = required_nonnegative_int_field json "bytes" in
      let* raw_blocks = optional_list_field json "blocks" in
      let* blocks = decode_list "blocks" decode_block_byte_pair raw_blocks in
      Ok (Slot_system_context { bytes; blocks })
  | other -> Error ("unknown forecast assembly slot: " ^ other)

let origin_label_of_json = function
  | `String s -> s
  | `Assoc _ as obj -> (
      match optional_nonblank_string obj "kind" with
      | Ok (Some k) -> (
          match optional_int_field obj "turn" with
          | Ok (Some t) -> Printf.sprintf "%s (turn %d)" k t
          | Ok None | Error _ -> (
              match optional_int_field obj "end_atom" with
              | Ok (Some a) -> Printf.sprintf "%s (end_atom %d)" k a
              | Ok None | Error _ -> (
                  match optional_nonblank_string obj "reason" with
                  | Ok (Some r) -> Printf.sprintf "%s (%s)" k r
                  | Ok None | Error _ -> (
                      match optional_nonblank_string obj "source" with
                      | Ok (Some src) -> Printf.sprintf "%s (%s)" k src
                      | Ok None | Error _ -> k))))
      | Ok None | Error _ -> Yojson.Safe.to_string obj)
  | other -> Yojson.Safe.to_string other

let decode_forecast_carried json =
  let* first_atom = required_nonnegative_int_field json "first_atom" in
  let* kept_atoms = required_nonnegative_int_field json "kept_atoms" in
  let* transmitted_bytes =
    required_nonnegative_int_field json "transmitted_bytes"
  in
  let* preamble_bytes = optional_int_field json "preamble_bytes" in
  let origin_label =
    if has_field json "origin" then origin_label_of_json (member "origin" json)
    else "unknown"
  in
  let* counted_tokens = optional_int_field json "counted_tokens" in
  Ok
    {
      first_atom;
      kept_atoms;
      transmitted_bytes;
      preamble_bytes;
      origin_label;
      counted_tokens;
    }

let decode_forecast_place json =
  let* walks_at = required_nonnegative_int_field json "walks_at" in
  let* declared_at = optional_int_field json "declared_at" in
  let* rest_obj = required_object_field json "rest" in
  let* kind = required_nonblank_string rest_obj "kind" in
  let* rest =
    match kind with
    | "serving" -> Ok Forecast_serving
    | "resting" ->
        let* release_at_unix = required_finite_float rest_obj "release_at" in
        let* release_basis =
          required_nonblank_string rest_obj "release_basis"
        in
        Ok (Forecast_resting { release_at_unix; release_basis })
    | other -> Error ("unknown forecast rest kind: " ^ other)
  in
  Ok { walks_at; declared_at; rest }

let decode_forecast_candidate json =
  let* runtime_id = required_nonblank_string json "runtime_id" in
  let* lane_obj = required_object_field json "lane" in
  let* lane =
    match optional_nonblank_string lane_obj "not_applicable" with
    | Ok (Some reason) -> Ok (Forecast_not_applicable reason)
    | Ok None -> Ok Forecast_agent_core
    | Error _ as err -> err
  in
  let* parts_obj = required_object_field json "parts" in
  let* parts =
    match optional_nonblank_string parts_obj "error" with
    | Ok (Some err) -> Ok (Forecast_parts_error err)
    | Ok None ->
        let* reserved_measured_on_turn =
          required_nonnegative_int_field parts_obj "reserved_measured_on_turn"
        in
        let* reserved_bytes =
          required_nonnegative_int_field parts_obj "reserved_bytes"
        in
        let* instructions_bytes =
          required_nonnegative_int_field parts_obj "instructions_bytes"
        in
        let* schemas_bytes =
          required_nonnegative_int_field parts_obj "schemas_bytes"
        in
        let* pinned_measured_on_turn =
          required_nonnegative_int_field parts_obj "pinned_measured_on_turn"
        in
        let* pinned_measured_on_runtime =
          required_nonblank_string parts_obj "pinned_measured_on_runtime"
        in
        let* pinned_bytes =
          required_nonnegative_int_field parts_obj "pinned_bytes"
        in
        let* raw_blocks = optional_list_field parts_obj "pinned_blocks" in
        let* pinned_blocks =
          decode_list "pinned_blocks" decode_block_byte_pair raw_blocks
        in
        Ok
          (Forecast_parts_ok
             {
               reserved_measured_on_turn;
               reserved_bytes;
               instructions_bytes;
               schemas_bytes;
               pinned_measured_on_turn;
               pinned_measured_on_runtime;
               pinned_bytes;
               pinned_blocks;
             })
    | Error _ as err -> err
  in
  let* history_atoms = required_nonnegative_int_field json "history_atoms" in
  let* carried_opt = optional_object_field json "carried" in
  let* carried =
    match carried_opt with
    | None -> Ok None
    | Some obj -> Result.map Option.some (decode_forecast_carried obj)
  in
  let* assembly =
    match member "assembly" json with
    | `Null -> Ok None
    | `List items ->
        Result.map Option.some (decode_list "assembly" decode_forecast_slot items)
    | bad -> field_type_error "assembly" "a list or null" bad
  in
  let* place_obj = required_object_field json "place" in
  let* place = decode_forecast_place place_obj in
  Ok { runtime_id; lane; parts; history_atoms; carried; assembly; place }

let decode_next_request_forecast json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* trace_id = required_nonblank_string body "trace_id" in
  let* checkpoint_messages =
    required_nonnegative_int_field body "checkpoint_messages"
  in
  let* wake_line_bytes = required_nonnegative_int_field body "wake_line_bytes" in
  let* walk_obj = required_object_field body "walk" in
  let* walk =
    match optional_nonblank_string walk_obj "refusal" with
    | Ok (Some msg) -> Ok (Walk_refused msg)
    | Ok None ->
        let* lane_id = required_nonblank_string walk_obj "lane_id" in
        let* declared = optional_string_list walk_obj "declared" in
        Ok (Walk_order { lane_id; declared })
    | Error _ as err -> err
  in
  let* raw_cands = optional_list_field body "candidates" in
  let* candidates =
    decode_list "candidates" decode_forecast_candidate raw_cands
  in
  Ok { keeper; trace_id; checkpoint_messages; wake_line_bytes; walk; candidates }

(* --- Turn Transcript --- *)

type transcript_line = {
  role : string;
  content : string;
  ts_unix : float;
}

type turn_transcript = {
  keeper : string;
  turn_ref : string;
  found : bool;
  user : transcript_line list;
  assistant : transcript_line list;
}

let decode_transcript_line json =
  let* role = required_nonblank_string json "role" in
  let* content = required_string_field json "content" in
  let* ts_unix =
    if has_field json "ts" then required_finite_float json "ts" else Ok 0.0
  in
  Ok { role; content; ts_unix }

let decode_turn_transcript json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* turn_ref = required_nonblank_string body "turn_ref" in
  let* found = required_bool_field body "found" in
  let* user_raw = optional_list_field body "user" in
  let* asst_raw = optional_list_field body "assistant" in
  let* user = decode_list "user" decode_transcript_line user_raw in
  let* assistant = decode_list "assistant" decode_transcript_line asst_raw in
  Ok { keeper; turn_ref; found; user; assistant }

(* --- Per-Keeper Tool Stats, Calls & Result --- *)

type keeper_tool_stat_row = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  last_used_at : string;
}

type keeper_tool_hourly_bucket = {
  hour : string;
  call_count : int;
  error_count : int;
}

type keeper_tool_stats = {
  keeper : string;
  window_hours : int;
  total_entries : int;
  health : string option;
  stale_reason : string option;
  tools : keeper_tool_stat_row list;
  timeline : keeper_tool_hourly_bucket list;
}

let decode_tool_stat_row json =
  let* name = required_nonblank_string json "name" in
  let* call_count = required_nonnegative_int_field json "call_count" in
  let* success_count = required_nonnegative_int_field json "success_count" in
  let* failure_count = required_nonnegative_int_field json "failure_count" in
  let* avg_duration_ms = required_nonnegative_int_field json "avg_duration_ms" in
  let* p95_duration_ms = required_nonnegative_int_field json "p95_duration_ms" in
  let* max_duration_ms = required_nonnegative_int_field json "max_duration_ms" in
  let* last_used_opt = optional_string_field json "last_used_at" in
  Ok
    {
      name;
      call_count;
      success_count;
      failure_count;
      avg_duration_ms;
      p95_duration_ms;
      max_duration_ms;
      last_used_at = Option.value ~default:"" last_used_opt;
    }

let decode_hourly_bucket json =
  let* hour = required_nonblank_string json "hour" in
  let* call_count = required_nonnegative_int_field json "call_count" in
  let* error_count = required_nonnegative_int_field json "error_count" in
  Ok { hour; call_count; error_count }

let decode_keeper_tool_stats json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* window_hours = required_nonnegative_int_field body "window_hours" in
  let* total_entries = required_nonnegative_int_field body "total_entries" in
  let* health = optional_nonblank_string body "health" in
  let* stale_reason = optional_nonblank_string body "stale_reason" in
  let* tools_raw = optional_list_field body "tools" in
  let* timeline_raw = optional_list_field body "timeline" in
  let* tools = decode_list "tools" decode_tool_stat_row tools_raw in
  let* timeline = decode_list "timeline" decode_hourly_bucket timeline_raw in
  Ok { keeper; window_hours; total_entries; health; stale_reason; tools; timeline }

type tool_call_entry = {
  ts_unix : float;
  tool : string;
  execution_id : string option;
  tool_use_id : string option;
  turn_kind : string option;
  duration_ms : float option;
  ok : bool option;
  disposition : string option;
  failure_class : string option;
  execution_mode : string option;
  batch_index : int option;
  batch_size : int option;
  definition_source : string option;
  input : Yojson.Safe.t;
  output : string;
  original_bytes : int option;
  truncated_to : int option;
  raw : Yojson.Safe.t;
}

type keeper_tool_calls_page = {
  keeper : string;
  count : int;
  health : string option;
  stale_reason : string option;
  coverage_gaps_count : int;
  entries : tool_call_entry list;
}

let decode_tool_call_entry json =
  let* ts_unix =
    if has_field json "ts" then required_finite_float json "ts" else Ok 0.0
  in
  let* tool = required_nonblank_string json "tool" in
  let* execution_id = optional_nonblank_string json "execution_id" in
  let* tool_use_id = optional_nonblank_string json "tool_use_id" in
  let* turn_kind = optional_nonblank_string json "turn_kind" in
  let* duration_ms = optional_finite_float json "duration_ms" in
  let* ok_field = optional_bool_field json "ok" in
  let* success_field = optional_bool_field json "success" in
  let* wire_outcome = optional_nonblank_string json "wire_outcome" in
  let* disposition = optional_nonblank_string json "disposition" in
  let ok =
    match ok_field with
    | Some _ as v -> v
    | None -> (
        match success_field with
        | Some _ as v -> v
        | None -> (
            match Option.map String.lowercase_ascii wire_outcome with
            | Some "ok" -> Some true
            | Some "error" -> Some false
            | Some _ | None -> (
                match Option.map String.lowercase_ascii disposition with
                | Some ("completed" | "succeeded") -> Some true
                | Some "failed" -> Some false
                | Some _ | None -> None)))
  in
  let* failure_class = optional_nonblank_string json "failure_class" in
  let execution_mode =
    match member "execution_mode" json with
    | `String s when not (String.equal (String.trim s) "") -> Some s
    | `Assoc _ as obj -> Some (Yojson.Safe.to_string obj)
    | _ -> None
  in
  let* batch_index = optional_int_field json "batch_index" in
  let* batch_size = optional_int_field json "batch_size" in
  let* definition_source = optional_nonblank_string json "definition_source" in
  let input =
    if has_field json "input" then member "input" json
    else if has_field json "args" then member "args" json
    else `Null
  in
  let output =
    match member "output" json with
    | `String s -> s
    | `Null -> ""
    | other -> Yojson.Safe.to_string other
  in
  let* result_bytes = optional_int_field json "result_bytes" in
  let* legacy_original_bytes = optional_int_field json "original_bytes" in
  let original_bytes =
    match result_bytes with
    | Some _ as v -> v
    | None -> legacy_original_bytes
  in
  let* truncated_to = optional_int_field json "truncated_to" in
  Ok
    {
      ts_unix;
      tool;
      execution_id;
      tool_use_id;
      turn_kind;
      duration_ms;
      ok;
      disposition;
      failure_class;
      execution_mode;
      batch_index;
      batch_size;
      definition_source;
      input;
      output;
      original_bytes;
      truncated_to;
      raw = json;
    }

let decode_keeper_tool_calls json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* health = optional_nonblank_string body "health" in
  let* stale_reason = optional_nonblank_string body "stale_reason" in
  let* gaps = optional_list_field body "coverage_gaps" in
  let* raw_entries = optional_list_field body "entries" in
  let* entries_raw = decode_list "entries" decode_tool_call_entry raw_entries in
  (* Sort newest-first so latest calls appear at top. *)
  let entries =
    List.sort
      (fun (a : tool_call_entry) (b : tool_call_entry) ->
        Float.compare b.ts_unix a.ts_unix)
      entries_raw
  in
  let* count_opt = optional_int_field body "count" in
  let count = Option.value ~default:(List.length entries) count_opt in
  Ok
    {
      keeper;
      count;
      health;
      stale_reason;
      coverage_gaps_count = List.length gaps;
      entries;
    }

type tool_result_response =
  | Tool_result_pending
  | Tool_result_unavailable of string
  | Tool_result_page of {
      keeper : string;
      execution_id : string;
      source_id : string;
      body_sha256 : string;
      recorded_bytes : int;
      is_error : bool;
      offset : int;
      next_offset : int;
      total_bytes : int;
      eof : bool;
      content : string;
      encoding : string;
    }

let decode_tool_result json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* execution_id = required_nonblank_string body "execution_id" in
  let* state = required_nonblank_string body "state" in
  match state with
  | "pending" -> Ok Tool_result_pending
  | "unavailable" ->
      let* reason = required_string_field body "reason" in
      Ok (Tool_result_unavailable reason)
  | "page" ->
      let* source_id = required_nonblank_string body "source_id" in
      let* body_sha256 = required_nonblank_string body "body_sha256" in
      let* recorded_bytes =
        required_nonnegative_int_field body "recorded_bytes"
      in
      let* is_error = required_bool_field body "is_error" in
      let* page = required_object_field body "page" in
      let* offset = required_nonnegative_int_field page "offset" in
      let* next_offset = required_nonnegative_int_field page "next_offset" in
      let* total_bytes = required_nonnegative_int_field page "total_bytes" in
      let* eof = required_bool_field page "eof" in
      let* content = required_string_field page "content" in
      let* encoding = required_nonblank_string page "encoding" in
      Ok
        (Tool_result_page
           {
             keeper;
             execution_id;
             source_id;
             body_sha256;
             recorded_bytes;
             is_error;
             offset;
             next_offset;
             total_bytes;
             eof;
             content;
             encoding;
           })
  | other -> Error ("unknown tool-result state: " ^ other)

let rec unfold_json_strings (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
      `Assoc (List.map (fun (k, v) -> (k, unfold_json_strings v)) fields)
  | `List items -> `List (List.map unfold_json_strings items)
  | `String text ->
      let trimmed = String.trim text in
      if
        String.length trimmed >= 2
        && (Char.equal trimmed.[0] '{' || Char.equal trimmed.[0] '[')
      then
        match Yojson.Safe.from_string trimmed with
        | (`Assoc _ | `List _) as doc -> unfold_json_strings doc
        | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> json
        | exception Yojson.Json_error _ -> json
      else json
  | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> json
