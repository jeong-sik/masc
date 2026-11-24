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

type memory_os_fact_item = {
  memory_id : string;
  claim : string;
  category : string;
  first_seen : float;
  current : bool;
}

type memory_os_change = {
  added : memory_os_fact_item list;
  removed : memory_os_fact_item list;
  retained : int;
  invalidated_count : int;
}

type memory_os_turn_snapshot = {
  recall_enabled : bool;
  revision : int;
  updated_at : float option;
  update_source_kind : string option;
  update_source_trace_id : string option;
  facts_shown : int;
  facts_current : int;
  facts : memory_os_fact_item list;
  change : memory_os_change;
  read_errors : string list;
}

type turn_records_page = {
  keeper : string;
  count : int;
  skipped_rows : int;
  health : string option;
  stale_reason : string option;
  live_turn_in_progress : bool;
  memory_os : memory_os_turn_snapshot option;
  entries : turn_record_entry list;
}

let decode_memory_os_fact_item json =
  let* memory_id = required_nonblank_string json "memory_id" in
  let* claim = required_string_field json "claim" in
  let* category_opt = optional_nonblank_string json "category" in
  let category = Option.value ~default:"fact" category_opt in
  let* first_seen_opt = optional_finite_float json "first_seen" in
  let first_seen = Option.value ~default:0.0 first_seen_opt in
  let* current_opt = optional_bool_field json "current" in
  let current = Option.value ~default:true current_opt in
  Ok { memory_id; claim; category; first_seen; current }

let decode_memory_os_turn_snapshot json =
  let* recall_opt = optional_bool_field json "recall_enabled" in
  let recall_enabled = Option.value ~default:false recall_opt in
  let* rev_opt = optional_int_field json "revision" in
  let revision = Option.value ~default:0 rev_opt in
  let* updated_at = optional_finite_float json "updated_at" in
  let* src_opt = optional_object_field json "update_source" in
  let* update_source_kind, update_source_trace_id =
    match src_opt with
    | None -> Ok (None, None)
    | Some s ->
        let* k = optional_nonblank_string s "kind" in
        let* tid = optional_nonblank_string s "trace_id" in
        Ok (k, tid)
  in
  let* err_list = optional_list_field json "read_errors" in
  let read_errors =
    List.filter_map
      (fun item ->
        match optional_nonblank_string item "error" with
        | Ok (Some e) -> Some e
        | Ok None | Error _ -> (
            match item with `String s when String.trim s <> "" -> Some s | _ -> None))
      err_list
  in
  let* facts_obj = optional_object_field json "facts" in
  let* facts_shown, facts_current, facts =
    match facts_obj with
    | None -> Ok (0, 0, [])
    | Some fo ->
        let* shown = optional_int_field fo "shown" in
        let* cur = optional_int_field fo "current" in
        let* raw_items = optional_list_field fo "items" in
        let* items = decode_list "facts.items" decode_memory_os_fact_item raw_items in
        Ok
          ( Option.value ~default:(List.length items) shown,
            Option.value ~default:(List.length items) cur,
            items )
  in
  let* ch_obj = optional_object_field json "change" in
  let* change =
    match ch_obj with
    | None -> Ok { added = []; removed = []; retained = 0; invalidated_count = 0 }
    | Some ch ->
        let* raw_add = optional_list_field ch "added" in
        let* raw_rem = optional_list_field ch "removed" in
        let* raw_inv = optional_list_field ch "invalidated" in
        let* ret = optional_int_field ch "retained" in
        let* added = decode_list "change.added" decode_memory_os_fact_item raw_add in
        let* removed =
          decode_list "change.removed" decode_memory_os_fact_item raw_rem
        in
        Ok
          {
            added;
            removed;
            retained = Option.value ~default:0 ret;
            invalidated_count = List.length raw_inv;
          }
  in
  Ok
    {
      recall_enabled;
      revision;
      updated_at;
      update_source_kind;
      update_source_trace_id;
      facts_shown;
      facts_current;
      facts;
      change;
      read_errors;
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
  let* memory_os_obj = optional_object_field body "memory_os" in
  let* memory_os =
    match memory_os_obj with
    | None -> Ok None
    | Some mo -> Result.map Option.some (decode_memory_os_turn_snapshot mo)
  in
  Ok
    {
      keeper;
      count;
      skipped_rows;
      health;
      stale_reason;
      live_turn_in_progress;
      memory_os;
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

(* --- Wave 3: Keeper Logs/Metrics & OAuth/GitHub Identity --- *)

let keeper_metrics_path ~keeper =
  (* Live server strictly rejects ?limit= on /api/v1/keepers/:name/metrics *)
  Printf.sprintf "/api/v1/keepers/%s/metrics" (percent_encode keeper)

let keeper_sandbox_logs_path ~keeper ?(tail = 200) () =
  Printf.sprintf "/api/v1/gate/keeper-sandbox-logs?name=%s&tail=%d"
    (percent_encode keeper) (max 1 tail)

let oauth_providers_path = "/api/v1/keepers/oauth/providers"

let oauth_attached_tools_path ~keeper =
  "/api/v1/keepers/oauth/attached-tools?keeper=" ^ percent_encode keeper

let oauth_attempt_status_path ~keeper ~provider ~attempt_id =
  Printf.sprintf
    "/api/v1/keepers/oauth/attempt-status?keeper=%s&provider=%s&attempt_id=%s"
    (percent_encode keeper) (percent_encode provider) (percent_encode attempt_id)

let oauth_login_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/oauth-login" (percent_encode keeper)

let oauth_identity_refresh_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/identity-refresh" (percent_encode keeper)

let oauth_identity_switch_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/identity-switch" (percent_encode keeper)

let oauth_disconnect_path = "/api/v1/keepers/oauth/disconnect"

let github_identity_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/github-identity" (percent_encode keeper)

let github_login_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/github-login" (percent_encode keeper)

let github_token_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/github-token" (percent_encode keeper)

type keeper_metrics_point = {
  ts_unix : float;
  trace_id : string;
  channel : string;
  latency_ms : int;
  cost_usd : float option;
  work_kind : string;
  tool_call_count : int;
  tools_used : string list;
  message_count : int option;
}

type keeper_metrics_snapshot = {
  keeper : string;
  sample_points : int;
  turn_points : int;
  heartbeat_points : int;
  proactive_points : int;
  tool_call_count : int;
  scanned_rows : int;
  skipped_rows : int;
  top_tools : (string * int) list;
  series : keeper_metrics_point list;
}

type sandbox_log_instance = {
  instance_id : string;
  instance_name : string;
  running : bool option;
  stdout : string;
  stderr : string;
  error : string option;
}

type keeper_sandbox_logs = {
  keeper : string;
  backend : string option;
  state : string;
  reason : string option;
  tail : int;
  instances : sandbox_log_instance list;
}

type oauth_provider_row = {
  id : string;
  label : string;
  app_state_kind : string;
  problem : string option;
  callback_url : string option;
}

type oauth_providers_snapshot = {
  providers : oauth_provider_row list;
  callback_url : string option;
  callback_problem : string option;
}

type oauth_attached_provider = {
  provider : string;
  provider_label : string;
  attached : bool;
  app_state_kind : string;
  enabled : bool option;
  switch_problem : string option;
  also_on : string list;
  discovered_at : float option;
  tools : string list;
  problem : string option;
}

type oauth_attached_tools_snapshot = {
  keeper : string;
  providers : oauth_attached_provider list;
}

type oauth_attempt_status = {
  kind : string;
  expires_at : float option;
  detail : string option;
}

type oauth_login_result =
  | Oauth_login_exchange of {
      provider : string;
      provider_label : string;
      authorize_url : string;
      attempt_id : string;
      expires_at : float option;
    }
  | Oauth_login_direct of {
      provider : string;
      provider_label : string;
      tool_count : int;
      message : string;
    }

type github_auth_probe = {
  authenticated : bool;
  login : string option;
  scopes : string list;
  error : string option;
}

type github_identity_observation = {
  keeper : string;
  hostname : string;
  config_dir : string;
  projected_token_env_names : string list;
  stored : github_auth_probe;
  effective : github_auth_probe;
  effective_probe_scope : string;
  checked_at_unix : float;
}

let int_or_0_kc json key =
  match optional_int_field json key with Ok (Some n) -> n | Ok None | Error _ -> 0

let float_or_0_kc json key =
  match optional_finite_float json key with
  | Ok (Some f) -> f
  | Ok None | Error _ -> 0.0

let decode_keeper_metrics_point json =
  let ts_unix = float_or_0_kc json "ts_unix" in
  let trace_id =
    match optional_string_field json "trace_id" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let channel =
    match optional_string_field json "channel" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "reactive"
  in
  let latency_ms = int_or_0_kc json "latency_ms" in
  let* cost_usd = optional_finite_float json "cost_usd" in
  let work_kind =
    match optional_string_field json "work_kind" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let tool_call_count = int_or_0_kc json "tool_call_count" in
  let* tools_used = optional_string_list json "tools_used" in
  let* message_count = optional_int_field json "message_count" in
  Ok
    {
      ts_unix;
      trace_id;
      channel;
      latency_ms;
      cost_usd;
      work_kind;
      tool_call_count;
      tools_used;
      message_count;
    }

let decode_keeper_metrics json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* series_items = optional_list_field body "series" in
  let* series = decode_list "series" decode_keeper_metrics_point series_items in
  let ws =
    match optional_object_field body "window_summary" with
    | Ok (Some w) -> w
    | Ok None | Error _ -> `Assoc []
  in
  let* top_tool_items = optional_list_field ws "top_tools" in
  let top_tools =
    List.filter_map
      (fun item ->
        match optional_nonblank_string item "tool" with
        | Ok (Some name) -> Some (name, int_or_0_kc item "count")
        | Ok None | Error _ -> None)
      top_tool_items
  in
  Ok
    {
      keeper;
      sample_points = int_or_0_kc ws "sample_points";
      turn_points = int_or_0_kc ws "turn_points";
      heartbeat_points = int_or_0_kc ws "heartbeat_points";
      proactive_points = int_or_0_kc ws "proactive_points";
      tool_call_count = int_or_0_kc ws "tool_call_count";
      scanned_rows = int_or_0_kc body "scanned_rows";
      skipped_rows = int_or_0_kc body "skipped_rows";
      top_tools;
      series;
    }

let decode_sandbox_log_instance json =
  let instance_id =
    match optional_string_field json "instance_id" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let instance_name =
    match optional_string_field json "instance_name" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> instance_id
  in
  let* running = optional_bool_field json "running" in
  let stdout =
    match optional_string_field json "stdout" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let stderr =
    match optional_string_field json "stderr" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* error = optional_nonblank_string json "error" in
  Ok { instance_id; instance_name; running; stdout; stderr; error }

let decode_keeper_sandbox_logs json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* backend = optional_nonblank_string body "backend" in
  let state =
    match optional_nonblank_string body "state" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "no_instance"
  in
  let* reason = optional_nonblank_string body "reason" in
  let tail = int_or_0_kc body "tail" in
  let* inst_items = optional_list_field body "instances" in
  let* instances =
    decode_list "instances" decode_sandbox_log_instance inst_items
  in
  Ok { keeper; backend; state; reason; tail; instances }

let extract_app_state json =
  match optional_object_field json "app_state" with
  | Ok (Some a) ->
      let kind =
        match optional_nonblank_string a "kind" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> "none"
      in
      let prob =
        match optional_nonblank_string a "problem" with Ok v -> v | Error _ -> None
      in
      (kind, prob)
  | Ok None | Error _ -> ("none", None)

let decode_oauth_provider_row json =
  let* id = required_nonblank_string json "id" in
  let label =
    match optional_nonblank_string json "label" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> id
  in
  let app_state_kind, app_problem = extract_app_state json in
  let top_problem =
    match optional_nonblank_string json "problem" with Ok v -> v | Error _ -> None
  in
  let problem =
    match top_problem with Some _ as p -> p | None -> app_problem
  in
  let callback_url =
    match optional_object_field json "callback" with
    | Ok (Some cb) -> (
        match optional_nonblank_string cb "url" with Ok v -> v | Error _ -> None)
    | Ok None | Error _ -> None
  in
  Ok { id; label; app_state_kind; problem; callback_url }

let decode_oauth_providers json =
  let* _, body = unwrap_v2_or_raw json in
  let* items = optional_list_field body "providers" in
  let* providers = decode_list "providers" decode_oauth_provider_row items in
  let callback_url, callback_problem =
    match optional_object_field body "callback" with
    | Ok (Some cb) ->
        let u =
          match optional_nonblank_string cb "url" with Ok v -> v | Error _ -> None
        in
        let p =
          match optional_nonblank_string cb "problem" with
          | Ok v -> v
          | Error _ -> None
        in
        (u, p)
    | Ok None | Error _ -> (None, None)
  in
  Ok { providers; callback_url; callback_problem }

let decode_oauth_attached_provider json =
  let* provider = required_nonblank_string json "provider" in
  let provider_label =
    match optional_nonblank_string json "provider_label" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> provider
  in
  let attached =
    match optional_bool_field json "attached" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let app_state_kind, app_prob = extract_app_state json in
  let* enabled = optional_bool_field json "enabled" in
  let* switch_problem = optional_nonblank_string json "switch_problem" in
  let* also_on = optional_string_list json "also_on" in
  let* discovered_at = optional_finite_float json "discovered_at" in
  let* tools = optional_string_list json "tools" in
  let top_prob =
    match optional_nonblank_string json "problem" with Ok v -> v | Error _ -> None
  in
  let problem = match top_prob with Some _ as p -> p | None -> app_prob in
  Ok
    {
      provider;
      provider_label;
      attached;
      app_state_kind;
      enabled;
      switch_problem;
      also_on;
      discovered_at;
      tools;
      problem;
    }

let decode_oauth_attached_tools json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* items = optional_list_field body "providers" in
  let* providers = decode_list "providers" decode_oauth_attached_provider items in
  Ok { keeper; providers }

let decode_oauth_attempt_status json =
  let* _, body = unwrap_v2_or_raw json in
  let* kind = required_nonblank_string body "kind" in
  let* expires_at = optional_finite_float body "expires_at" in
  let detail =
    match optional_nonblank_string body "error" with
    | Ok (Some s) -> Some s
    | Ok None | Error _ -> (
        match optional_nonblank_string body "detail" with
        | Ok v -> v
        | Error _ -> None)
  in
  Ok { kind; expires_at; detail }

let decode_oauth_login_result json =
  let* _, body = unwrap_v2_or_raw json in
  let* provider = required_nonblank_string body "provider" in
  let provider_label =
    match optional_nonblank_string body "provider_label" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> provider
  in
  match optional_nonblank_string body "authorize_url" with
  | Ok (Some authorize_url) ->
      let* attempt_id = required_nonblank_string body "attempt_id" in
      let* expires_at = optional_finite_float body "expires_at" in
      Ok
        (Oauth_login_exchange
           { provider; provider_label; authorize_url; attempt_id; expires_at })
  | Ok None | Error _ ->
      let tool_count = int_or_0_kc body "tool_count" in
      let message =
        match optional_string_field body "message" with
        | Ok (Some s) -> s
        | Ok None | Error _ -> "Connected"
      in
      Ok (Oauth_login_direct { provider; provider_label; tool_count; message })

let decode_github_auth_probe json =
  let authenticated =
    match optional_bool_field json "authenticated" with
    | Ok (Some b) -> b
    | Ok None | Error _ -> false
  in
  let* login = optional_nonblank_string json "login" in
  let* scopes = optional_string_list json "scopes" in
  let* error = optional_nonblank_string json "error" in
  Ok { authenticated; login; scopes; error }

let decode_github_identity json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let hostname =
    match optional_nonblank_string body "hostname" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> "github.com"
  in
  let config_dir =
    match optional_string_field body "config_dir" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let* projected_token_env_names =
    optional_string_list body "projected_token_env_names"
  in
  let* stored_obj = required_object_field body "stored" in
  let* stored = decode_github_auth_probe stored_obj in
  let* eff_obj = required_object_field body "effective" in
  let* effective = decode_github_auth_probe eff_obj in
  let effective_probe_scope =
    match optional_string_field body "effective_probe_scope" with
    | Ok (Some s) -> s
    | Ok None | Error _ -> ""
  in
  let checked_at_unix = float_or_0_kc body "checked_at_unix" in
  Ok
    {
      keeper;
      hostname;
      config_dir;
      projected_token_env_names;
      stored;
      effective;
      effective_probe_scope;
      checked_at_unix;
    }

let encode_oauth_provider_body ~provider =
  `Assoc [ ("provider", `String provider) ]

let encode_oauth_switch_body ~provider ~enabled =
  `Assoc [ ("provider", `String provider); ("enabled", `Bool enabled) ]

let encode_oauth_disconnect_body ~keeper ~provider =
  `Assoc [ ("keeper", `String keeper); ("provider", `String provider) ]

let encode_github_token_body ~token ?hostname () =
  `Assoc
    (("token", `String token)
    ::
    (match hostname with
    | Some h when not (String.equal (String.trim h) "") ->
        [ ("hostname", `String (String.trim h)) ]
    | Some _ | None -> []))

(* --- Wave 4 Layer 1: Per-Turn Flow, Checkpoints, Operator Note & Control --- *)

let keeper_turn_flow_path ~keeper ~trace_id ~turn_id ?(limit = 500) () =
  Printf.sprintf "/api/v1/keepers/%s/runtime-trace?trace_id=%s&turn_id=%d&limit=%d"
    (percent_encode keeper) (percent_encode trace_id) turn_id
    (max 1 (min 500 limit))

let keeper_checkpoints_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/checkpoints" (percent_encode keeper)

let keeper_operator_note_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/operator-note" (percent_encode keeper)

let keeper_boot_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/boot" (percent_encode keeper)

let keeper_up_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/up" (percent_encode keeper)

let keeper_shutdown_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/shutdown" (percent_encode keeper)

let keeper_reset_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/reset" (percent_encode keeper)

let keeper_clear_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/clear" (percent_encode keeper)

let keeper_directive_path ~keeper =
  Printf.sprintf "/api/v1/keepers/%s/directive" (percent_encode keeper)

let keeper_run_next_path = "/api/v1/keepers/turn/run-next"

type turn_intake_source = {
  stimulus_id : string;
  source_kind : string option;
  snapshot_ref : string;
  admitted_revision : string;
  first_admitted_at : float option;
}

type turn_intake_state =
  | Intake_observed of {
      channel : string option;
      sources : turn_intake_source list;
    }
  | Intake_not_recorded of string
  | Intake_unavailable of string
  | Intake_ambiguous of int

type turn_source_receipt = {
  transition_id : string;
  event_id : string;
  applied_at : float;
  kind : string;
}

type turn_source_outcome = {
  stimulus_id : string;
  snapshot_ref : string;
  admitted_revision : string;
  receipts : turn_source_receipt list;
}

type turn_source_outcomes =
  | Outcomes_observed of {
      observed_at : float;
      coverage_state : string;
      rows_inspected : int;
      sources : turn_source_outcome list;
    }
  | Outcomes_unavailable of string

type turn_flow_event = {
  event : string;
  status : string;
  runtime_id : string option;
  routing_action : string option;
  routing_reason : string option;
}

type turn_flow = {
  keeper : string;
  trace_id : string;
  turn_id : int;
  manifest_total_rows : int;
  manifest_total_rows_exact : bool option;
  intake : turn_intake_state;
  outcomes : turn_source_outcomes;
  events : turn_flow_event list;
}

let decode_turn_intake_source json =
  let* stimulus_id = required_nonblank_string json "stimulus_id" in
  let* source_kind = optional_nonblank_string json "source_kind" in
  let* snapshot_ref = required_nonblank_string json "source_snapshot_ref" in
  let* admitted_revision = required_nonblank_string json "admitted_revision" in
  let* first_admitted_at = optional_finite_float json "first_admitted_at" in
  Ok { stimulus_id; source_kind; snapshot_ref; admitted_revision; first_admitted_at }

let decode_turn_source_receipt json =
  let* transition_id = required_nonblank_string json "transition_id" in
  let* event_id = required_nonblank_string json "event_id" in
  let* applied_at = required_finite_float json "applied_at" in
  let* kind = required_nonblank_string json "kind" in
  Ok { transition_id; event_id; applied_at; kind }

let decode_turn_source_outcome json =
  let* stimulus_id = required_nonblank_string json "stimulus_id" in
  let* snapshot_ref = required_nonblank_string json "source_snapshot_ref" in
  let* admitted_revision = required_nonblank_string json "admitted_revision" in
  let* raw_receipts = required_list_field json "receipts" in
  let* receipts = decode_list "receipts" decode_turn_source_receipt raw_receipts in
  Ok { stimulus_id; snapshot_ref; admitted_revision; receipts }

let decode_turn_source_outcomes raw =
  match raw with
  | `Null -> Outcomes_unavailable "source_outcomes not recorded on this server"
  | `Assoc _ -> (
      match optional_nonblank_string raw "state" with
      | Ok (Some "unavailable") ->
          let reason =
            match optional_nonblank_string raw "reason" with
            | Ok (Some r) -> r
            | Ok None | Error _ -> "unavailable"
          in
          Outcomes_unavailable reason
      | Ok (Some "observed") -> (
          let res =
            let* observed_at = required_finite_float raw "observed_at" in
            let* cov = required_object_field raw "coverage" in
            let* coverage_state = required_nonblank_string cov "state" in
            let* rows_inspected = required_nonnegative_int_field cov "rows_inspected" in
            let* raw_sources = required_list_field raw "sources" in
            let* sources =
              decode_list "source_outcomes.sources" decode_turn_source_outcome
                raw_sources
            in
            Ok (Outcomes_observed { observed_at; coverage_state; rows_inspected; sources })
          in
          match res with Ok o -> o | Error e -> Outcomes_unavailable e)
      | Ok (Some other) -> Outcomes_unavailable ("unknown outcomes state: " ^ other)
      | Ok None | Error _ -> Outcomes_unavailable "malformed source_outcomes")
  | _ -> Outcomes_unavailable "malformed source_outcomes"

let decode_turn_flow ~keeper ~trace_id ~turn_id json =
  let* _, body = unwrap_v2_or_raw json in
  let* resp_keeper = required_nonblank_string body "keeper" in
  let* resp_trace = required_nonblank_string body "trace_id" in
  let* resp_turn = optional_int_field body "turn_id" in
  if
    not
      (String.equal resp_keeper keeper
       && String.equal resp_trace trace_id
       && Option.equal Int.equal resp_turn (Some turn_id))
  then
    Error
      (Printf.sprintf "runtime-trace mismatch: expected %s %s#%d" keeper
         trace_id turn_id)
  else
    let* manifest_total_rows_opt = optional_int_field body "manifest_total_rows" in
    let manifest_total_rows = Option.value ~default:0 manifest_total_rows_opt in
    let* manifest_total_rows_exact =
      optional_bool_field body "manifest_total_rows_exact"
    in
    let* raw_rows = optional_list_field body "manifest_rows" in
    let* row_checks =
      decode_list "manifest_rows"
        (fun row ->
          let* rk = optional_nonblank_string row "keeper_name" in
          let* rt = optional_nonblank_string row "trace_id" in
          let* rturn = optional_int_field row "keeper_turn_id" in
          let mismatch =
            (match rk with Some k -> not (String.equal k keeper) | None -> false)
            || (match rt with Some t -> not (String.equal t trace_id) | None -> false)
            || (match rturn with Some n -> not (Int.equal n turn_id) | None -> false)
          in
          if mismatch then Error "runtime-trace contains a row for another keeper turn"
          else
            let* event = required_nonblank_string row "event" in
            let* status_opt = optional_nonblank_string row "status" in
            let status = Option.value ~default:"unknown" status_opt in
            let* runtime_id = optional_nonblank_string row "runtime_id" in
            let* dec_opt = optional_object_field row "decision" in
            let* routing_action, routing_reason =
              match dec_opt with
              | None -> Ok (None, None)
              | Some d ->
                  let* act = optional_nonblank_string d "routing_action" in
                  let* rsn = optional_nonblank_string d "routing_reason" in
                  Ok (act, rsn)
            in
            Ok
              ( { event; status; runtime_id; routing_action; routing_reason },
                dec_opt ))
        raw_rows
    in
    let events = List.map fst row_checks in
    let starts =
      List.filter (fun (ev, _) -> String.equal ev.event "turn_started") row_checks
    in
    let scanned_starts =
      match optional_object_field body "runtime_lens" with
      | Ok (Some lens) -> (
          match optional_object_field lens "axes" with
          | Ok (Some axes) -> (
              match optional_object_field axes "lifecycle" with
              | Ok (Some lc) -> (
                  match optional_int_field lc "turn_started_count" with
                  | Ok (Some n) when n >= 0 -> Some n
                  | Ok _ | Error _ -> None)
              | Ok None | Error _ -> None)
          | Ok None | Error _ -> None)
      | Ok None | Error _ -> None
    in
    let observed_starts =
      Int.max (List.length starts) (Option.value ~default:0 scanned_starts)
    in
    let diag_ok =
      match optional_object_field body "manifest_scan_diagnostics" with
      | Ok (Some d) -> (
          let schema_ok =
            match optional_nonblank_string d "schema" with
            | Ok (Some s) ->
                String.equal s "keeper.runtime_manifest_scan_diagnostics.v1"
            | Ok None | Error _ -> false
          in
          match
            ( required_nonnegative_int_field d "invalid_manifest_row_count",
              required_nonnegative_int_field d "invalid_json_row_count",
              required_nonnegative_int_field d
                "unsupported_event_unattributed_count" )
          with
          | Ok bad1, Ok bad2, Ok bad3 ->
              schema_ok && bad1 = 0 && bad2 = 0 && bad3 = 0
          | (Error _, _, _) | (_, Error _, _) | (_, _, Error _) -> false)
      | Ok None | Error _ -> false
    in
    let* intake =
      if observed_starts > 1 then Ok (Intake_ambiguous observed_starts)
      else if manifest_total_rows_exact <> Some true then
        Ok
          (Intake_unavailable
             (if manifest_total_rows_exact = Some false then
                "partial manifest scan: cannot prove single turn start"
              else "manifest scan completeness unrecorded"))
      else if not diag_ok then
        Ok (Intake_unavailable "manifest scan diagnostics report unreadable rows")
      else
        match scanned_starts with
        | Some n when not (Int.equal n (List.length starts)) ->
            Ok (Intake_unavailable "scanned start count mismatches returned rows")
        | Some _ | None -> (
            match starts with
            | [] -> Ok (Intake_not_recorded "no turn_started row in scan range")
            | (_, None) :: _ ->
                Ok (Intake_not_recorded "turn_started decision missing")
            | (_, Some dec) :: _ ->
                if not (has_field dec "intake_sources") then
                  Ok (Intake_not_recorded "no intake_sources recorded")
                else
                  let* raw_srcs = required_list_field dec "intake_sources" in
                  let* sources =
                    decode_list "intake_sources" decode_turn_intake_source raw_srcs
                  in
                  let* channel = optional_nonblank_string dec "channel" in
                  Ok (Intake_observed { channel; sources }))
    in
    let outcomes =
      match intake with
      | Intake_observed _ ->
          if has_field body "source_outcomes" then
            decode_turn_source_outcomes (member "source_outcomes" body)
          else Outcomes_unavailable "source_outcomes not recorded"
      | Intake_not_recorded _ | Intake_unavailable _ | Intake_ambiguous _ ->
          Outcomes_unavailable "exact turn intake required to join outcomes"
    in
    Ok
      {
        keeper;
        trace_id;
        turn_id;
        manifest_total_rows;
        manifest_total_rows_exact;
        intake;
        outcomes;
        events;
      }

type checkpoint_summary = {
  snapshot_id : string;
  source_kind : string;
  is_current : bool;
  status : string;
  created_at : float option;
  message_count : int option;
  system_prompt_present : bool option;
  latest_preview : string option;
  size_bytes : int option;
  error_kind : string option;
  error_detail : string option;
}

type keeper_checkpoints_inventory = {
  keeper : string;
  trace_id : string;
  current_status : string;
  current : checkpoint_summary option;
  current_error_kind : string option;
  current_error_detail : string option;
  history : checkpoint_summary list;
  history_errors : checkpoint_summary list;
}

type checkpoint_purge_report = {
  messages_before : int;
  messages_after : int;
  bytes_before : int;
  bytes_after : int;
  bytes_removed : int;
  reasoning_blocks_stripped : int;
  tool_results_cleared : int;
  messages_dropped_at_structural_break : int;
}

type checkpoint_purge_result = {
  action : string;
  keeper : string;
  trace_id : string;
  apply_allowed : bool;
  applied : bool;
  backup_path : string option;
  report : checkpoint_purge_report;
  warnings : string list;
  inventory : keeper_checkpoints_inventory option;
}

type checkpoint_delete_result = {
  deleted : string list;
  missing : string list;
  refused : string list;
  failed : string list;
  inventory : keeper_checkpoints_inventory option;
}

type keeper_operator_note = {
  keeper : string;
  pending : bool;
  text : string;
  created_at : float;
  created_by : string;
  consumed_at : float option;
  consumed_turn : int option;
}

type keeper_directive =
  | Directive_pause
  | Directive_wakeup
  | Directive_resume of { operator_operation_id : string }

let string_or_json_opt json key =
  match member key json with
  | `Null -> None
  | `String s ->
      let t = String.trim s in
      if String.equal t "" then None else Some t
  | other -> Some (Yojson.Safe.to_string other)

let decode_checkpoint_summary json =
  let* snapshot_id = required_nonblank_string json "snapshot_id" in
  let* source_kind_opt = optional_nonblank_string json "source_kind" in
  let source_kind = Option.value ~default:"unknown" source_kind_opt in
  let* is_current_opt = optional_bool_field json "is_current" in
  let is_current = Option.value ~default:false is_current_opt in
  let* status_opt = optional_nonblank_string json "status" in
  let status = Option.value ~default:"unknown" status_opt in
  let* created_at = optional_finite_float json "created_at" in
  let* message_count = optional_int_field json "message_count" in
  let* system_prompt_present = optional_bool_field json "system_prompt_present" in
  let* latest_preview = optional_nonblank_string json "latest_preview" in
  let* file_stat = optional_object_field json "file_stat" in
  let* size_bytes =
    match file_stat with
    | Some st -> optional_int_field st "size_bytes"
    | None -> Ok None
  in
  let* error_kind = optional_nonblank_string json "error_kind" in
  let error_detail = string_or_json_opt json "error_detail" in
  Ok
    {
      snapshot_id;
      source_kind;
      is_current;
      status;
      created_at;
      message_count;
      system_prompt_present;
      latest_preview;
      size_bytes;
      error_kind;
      error_detail;
    }

let decode_keeper_checkpoints_inventory json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* trace_id_opt = optional_nonblank_string body "trace_id" in
  let trace_id = Option.value ~default:"" trace_id_opt in
  let* current_status_opt = optional_nonblank_string body "current_status" in
  let current_status = Option.value ~default:"missing" current_status_opt in
  let* current_obj = optional_object_field body "current" in
  let* current =
    match current_obj with
    | None -> Ok None
    | Some c -> Result.map Option.some (decode_checkpoint_summary c)
  in
  let* cur_err = optional_object_field body "current_error" in
  let current_error_kind, current_error_detail =
    match cur_err with
    | None -> (None, None)
    | Some e ->
        let k =
          match optional_nonblank_string e "kind" with
          | Ok v -> v
          | Error _ -> None
        in
        let d = string_or_json_opt e "detail" in
        (k, d)
  in
  let* raw_hist = optional_list_field body "history" in
  let* history = decode_list "history" decode_checkpoint_summary raw_hist in
  let* raw_errs = optional_list_field body "history_errors" in
  let* history_errors =
    decode_list "history_errors" decode_checkpoint_summary raw_errs
  in
  Ok
    {
      keeper;
      trace_id;
      current_status;
      current;
      current_error_kind;
      current_error_detail;
      history;
      history_errors;
    }

let decode_checkpoint_purge_result json =
  let* _, body = unwrap_v2_or_raw json in
  let* action_opt = optional_nonblank_string body "action" in
  let action = Option.value ~default:"preview_purge" action_opt in
  let* keeper = required_nonblank_string body "keeper" in
  let* trace_id_opt = optional_nonblank_string body "trace_id" in
  let trace_id = Option.value ~default:"" trace_id_opt in
  let* apply_allowed_opt = optional_bool_field body "apply_allowed" in
  let apply_allowed = Option.value ~default:false apply_allowed_opt in
  let* applied_opt = optional_bool_field body "applied" in
  let applied = Option.value ~default:false applied_opt in
  let* backup_path = optional_nonblank_string body "backup_path" in
  let* rpt = required_object_field body "report" in
  let report =
    {
      messages_before = int_or_0_kc rpt "messages_before";
      messages_after = int_or_0_kc rpt "messages_after";
      bytes_before = int_or_0_kc rpt "bytes_before";
      bytes_after = int_or_0_kc rpt "bytes_after";
      bytes_removed = int_or_0_kc rpt "bytes_removed";
      reasoning_blocks_stripped = int_or_0_kc rpt "reasoning_blocks_stripped";
      tool_results_cleared = int_or_0_kc rpt "tool_results_cleared";
      messages_dropped_at_structural_break =
        int_or_0_kc rpt "messages_dropped_at_structural_break";
    }
  in
  let* warnings = optional_string_list body "warnings" in
  let* inv_obj = optional_object_field body "inventory" in
  let inventory =
    match inv_obj with
    | None -> None
    | Some inv -> (
        match decode_keeper_checkpoints_inventory inv with
        | Ok i -> Some i
        | Error _ -> None)
  in
  Ok
    {
      action;
      keeper;
      trace_id;
      apply_allowed;
      applied;
      backup_path;
      report;
      warnings;
      inventory;
    }

let decode_checkpoint_delete_result json =
  let* _, body = unwrap_v2_or_raw json in
  let* deleted = optional_string_list body "deleted_snapshot_ids" in
  let* missing = optional_string_list body "missing_snapshot_ids" in
  let* refused = optional_string_list body "refused_snapshot_ids" in
  let* failed = optional_string_list body "failed_snapshot_ids" in
  let* inv_obj = optional_object_field body "inventory" in
  let inventory =
    match inv_obj with
    | None -> None
    | Some inv -> (
        match decode_keeper_checkpoints_inventory inv with
        | Ok i -> Some i
        | Error _ -> None)
  in
  Ok { deleted; missing; refused; failed; inventory }

let decode_keeper_operator_note json =
  let* _, body = unwrap_v2_or_raw json in
  let* keeper = required_nonblank_string body "keeper" in
  let* note = required_object_field body "note" in
  let* text = required_string_field note "text" in
  let* created_at = required_finite_float note "created_at" in
  let* created_by_opt = optional_nonblank_string note "created_by" in
  let created_by = Option.value ~default:"operator" created_by_opt in
  let* consumed_at = optional_finite_float note "consumed_at" in
  let* consumed_turn = optional_int_field note "consumed_turn" in
  let* pending_opt = optional_bool_field body "pending" in
  let pending = Option.value ~default:(Option.is_none consumed_at) pending_opt in
  Ok { keeper; pending; text; created_at; created_by; consumed_at; consumed_turn }

let expected_workspace_json (ws : Wire_work.expected_workspace) =
  `Assoc
    [
      ("base_path", `String ws.base_path);
      ("masc_root", `String ws.masc_root);
    ]

let encode_keeper_up_body ?expected_workspace () =
  match expected_workspace with
  | None -> `Assoc []
  | Some ws -> `Assoc [ ("expected_workspace", expected_workspace_json ws) ]

let encode_keeper_clear_body ~reason ~preserve_system_prompt =
  `Assoc
    [
      ("reason", `String (String.trim reason));
      ("preserve_system_prompt", `Bool preserve_system_prompt);
    ]

let encode_keeper_directive_body ~expected_workspace directive =
  let base =
    match directive with
    | Directive_pause -> [ ("action", `String "pause") ]
    | Directive_wakeup -> [ ("action", `String "wakeup") ]
    | Directive_resume { operator_operation_id } ->
        [
          ("action", `String "resume");
          ("operator_operation_id", `String operator_operation_id);
        ]
  in
  `Assoc (base @ [ ("expected_workspace", expected_workspace_json expected_workspace) ])

let encode_checkpoint_purge_body ~apply =
  `Assoc [ ("action", `String (if apply then "apply_purge" else "preview_purge")) ]

let encode_checkpoint_delete_history_body ~snapshot_ids =
  `Assoc
    [
      ("action", `String "delete_history");
      ("snapshot_ids", `List (List.map (fun s -> `String s) snapshot_ids));
    ]

let encode_operator_note_body ~text = `Assoc [ ("text", `String text) ]

let encode_keeper_run_next_body ~keeper ~request_id ?interrupt_token () =
  let base =
    [ ("name", `String keeper); ("request_id", `String request_id) ]
  in
  let extra =
    match interrupt_token with
    | Some tok when not (String.equal (String.trim tok) "") ->
        [ ("interrupt_token", `String (String.trim tok)) ]
    | Some _ | None -> []
  in
  `Assoc (base @ extra)
