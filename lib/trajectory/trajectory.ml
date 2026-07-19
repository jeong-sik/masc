(** Trajectory — JSONL-based tool call trajectory logging for Keeper Harness.

    Records exact tool call invocations (pre + post) to enable:
    - Deterministic replay of agent behavior
    - Tool count, result, and latency observation
    - Behavioral evaluation via eval_harness.ml

    Model usage and cost come from OAS inference facts. Tool names are not a
    pricing signal and are never used to estimate cost or control recurrence.

    Each keeper session produces a trajectory file at:
      .masc/keepers/{keeper_name}/trajectories/v1/{trace_id}.jsonl

    @since 2.73.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type tool_call_outcome =
  | Tool_succeeded of string
  | Tool_failed of string

type tool_call_entry = {
  ts : float;                       (** Unix timestamp *)
  ts_iso : string;                  (** ISO8601 string *)
  keeper_turn_id : int;             (** Absolute MASC Keeper turn *)
  oas_turn : int;                   (** OAS Agent turn within this Keeper turn *)
  schedule : Agent_sdk.Tool.schedule;
      (** Exact OAS scheduler placement for this occurrence. *)
  tool_use_id : string;
      (** Opaque provider/OAS correlation evidence. May be blank or repeated;
          never an occurrence identity or join key. *)
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type enforces the
          JSON object invariant without a second string representation. *)
  outcome : tool_call_outcome;
  duration_ms : int;                (** Wall-clock execution time *)
  execution_id : Ids.Execution_id.t;
      (** RFC-0233 canonical join key minted at the dispatch boundary; the
          tool_calls JSONL row for the same execution carries the identical
          value. *)
}

type invalid_entry_counts = {
  missing_required_field : int;
  invalid_field : int;
  unexpected_field : int;
  duplicate_field : int;
  unsupported_row_type : int;
  malformed_json : int;
}

type entry_decode_summary = {
  invalid_entry_count : int;
  invalid_reasons : invalid_entry_counts;
}

type trajectory_read_error = {
  path : string;
  message : string;
}

type entries_read_result = {
  entries : tool_call_entry list;
  decode : entry_decode_summary;
  io_errors : trajectory_read_error list;
}

type entry_field =
  | Schema
  | Row_type
  | Timestamp
  | Timestamp_iso
  | Keeper_turn_id
  | Oas_turn
  | Schedule
  | Planned_index
  | Batch_index
  | Batch_size
  | Execution_mode
  | Tool_use_id
  | Tool_name
  | Arguments
  | Tool_outcome
  | Duration_ms
  | Execution_id
  | Keeper_name
  | Trace_id
  | Generation
  | Observed_oas_turn_count
  | Total_tool_calls
  | Trajectory_outcome
  | Started_at
  | Ended_at
  | Block_index
  | Thinking_block

type entry_decode_error =
  | Missing_required_field of entry_field
  | Invalid_field of entry_field
  | Unexpected_field of string
  | Duplicate_field of string
  | Unsupported_row_type of string
  | Malformed_json

type tool_call_entry_decode =
  | Decoded_entry of tool_call_entry
  | Non_entry_row
  | Invalid_entry of entry_decode_error

let entry_field_to_string = function
  | Schema -> "schema"
  | Row_type -> "row_type"
  | Timestamp -> "timestamp"
  | Timestamp_iso -> "timestamp_iso"
  | Keeper_turn_id -> "keeper_turn_id"
  | Oas_turn -> "oas_turn"
  | Schedule -> "schedule"
  | Planned_index -> "planned_index"
  | Batch_index -> "batch_index"
  | Batch_size -> "batch_size"
  | Execution_mode -> "execution_mode"
  | Tool_use_id -> "tool_use_id"
  | Tool_name -> "tool_name"
  | Arguments -> "arguments"
  | Tool_outcome -> "tool_outcome"
  | Duration_ms -> "duration_ms"
  | Execution_id -> "execution_id"
  | Keeper_name -> "keeper_name"
  | Trace_id -> "trace_id"
  | Generation -> "generation"
  | Observed_oas_turn_count -> "observed_oas_turn_count"
  | Total_tool_calls -> "total_tool_calls"
  | Trajectory_outcome -> "trajectory_outcome"
  | Started_at -> "started_at"
  | Ended_at -> "ended_at"
  | Block_index -> "block_index"
  | Thinking_block -> "thinking_block"

let entry_decode_error_to_string = function
  | Missing_required_field field ->
      Printf.sprintf "missing required %s" (entry_field_to_string field)
  | Invalid_field field ->
      Printf.sprintf "invalid %s" (entry_field_to_string field)
  | Unexpected_field field -> Printf.sprintf "unexpected field %S" field
  | Duplicate_field field -> Printf.sprintf "duplicate field %S" field
  | Unsupported_row_type row_type ->
      Printf.sprintf "unsupported row type %S" row_type
  | Malformed_json -> "malformed JSON"

let make_tool_call_entry ~ts ~ts_iso ~keeper_turn_id ~invocation ~tool_name
    ~arguments ~outcome ~duration_ms ~execution_id =
  let rec validate_argument_keys seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
        if Set_util.StringSet.mem key seen then Error (Duplicate_field key)
        else
          validate_argument_keys (Set_util.StringSet.add key seen) rest
  in
  let oas_turn = Agent_sdk.Tool.Invocation.turn invocation in
  let schedule = Agent_sdk.Tool.Invocation.schedule invocation in
  let tool_use_id = Agent_sdk.Tool.Invocation.tool_use_id invocation in
  if not (Float.is_finite ts) then Error (Invalid_field Timestamp)
  else if String.trim ts_iso = "" then Error (Invalid_field Timestamp_iso)
  else if keeper_turn_id <= 0 then Error (Invalid_field Keeper_turn_id)
  else if oas_turn < 0 then Error (Invalid_field Oas_turn)
  else if schedule.planned_index < 0 then Error (Invalid_field Planned_index)
  else if schedule.batch_index < 0 then Error (Invalid_field Batch_index)
  else if schedule.batch_size <= 0 then Error (Invalid_field Batch_size)
  else if String.trim tool_name = "" then Error (Invalid_field Tool_name)
  else if duration_ms < 0 then Error (Invalid_field Duration_ms)
  else if String.trim (Ids.Execution_id.to_string execution_id) = "" then
    Error (Invalid_field Execution_id)
  else
    match outcome with
    | Tool_failed error when String.trim error = "" ->
        Error (Invalid_field Tool_outcome)
    | Tool_succeeded _ | Tool_failed _ ->
        (match validate_argument_keys Set_util.StringSet.empty arguments with
         | Error _ as error -> error
         | Ok () ->
             Ok
               { ts
               ; ts_iso
               ; keeper_turn_id
               ; oas_turn
               ; schedule
               ; tool_use_id
               ; tool_name
               ; arguments
               ; outcome
               ; duration_ms
               ; execution_id
               })

type trajectory_outcome =
  | Completed
  | Failed of string
  | Input_required
  | Cancelled

type trajectory = {
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int;
  generation : int;
  started_at : float;
  ended_at : float;
  observed_oas_turn_count : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
}

(* ================================================================ *)
(* Thinking entries                                                  *)
(* ================================================================ *)

type thinking_entry = {
  ts : float;
  ts_iso : string;
  keeper_turn_id : int;
  oas_turn : int;
  block_index : int;
  block : Agent_sdk.Types.content_block;
}

let make_thinking_entry ~ts ~ts_iso ~keeper_turn_id ~oas_turn ~block_index
    ~block =
  if not (Float.is_finite ts) then Error (Invalid_field Timestamp)
  else if String.trim ts_iso = "" then Error (Invalid_field Timestamp_iso)
  else if keeper_turn_id <= 0 then Error (Invalid_field Keeper_turn_id)
  else if oas_turn < 0 then Error (Invalid_field Oas_turn)
  else if block_index < 0 then Error (Invalid_field Block_index)
  else
    match block with
    | (Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.ReasoningDetails _
      | Agent_sdk.Types.RedactedThinking _) as block ->
        Ok { ts; ts_iso; keeper_turn_id; oas_turn; block_index; block }
    | Agent_sdk.Types.Text _
    | Agent_sdk.Types.ToolUse _
    | Agent_sdk.Types.ToolResult _
    | Agent_sdk.Types.Image _
    | Agent_sdk.Types.Document _
    | Agent_sdk.Types.Audio _ ->
        Error (Invalid_field Thinking_block)

type trajectory_line =
  | Tool_call of tool_call_entry
  | Thinking of thinking_entry

type trajectory_line_decode_summary = {
  tool_call_count : int;
  thinking_count : int;
  skipped_summary_count : int;
  invalid_line_count : int;
  invalid_reasons : invalid_entry_counts;
}

type trajectory_lines_read_result = {
  lines : trajectory_line list;
  line_decode : trajectory_line_decode_summary;
  io_errors : trajectory_read_error list;
}

type trajectory_scan_limit_error =
  | Non_positive_physical_row_limit of int
  | Non_positive_byte_limit of int64

type trajectory_scan_limits = {
  max_physical_rows : int;
  max_bytes : int64;
}

let make_trajectory_scan_limits ~max_physical_rows ~max_bytes =
  if max_physical_rows <= 0 then
    Error (Non_positive_physical_row_limit max_physical_rows)
  else if max_bytes <= 0L then Error (Non_positive_byte_limit max_bytes)
  else Ok { max_physical_rows; max_bytes }

let trajectory_scan_limit_error_to_string = function
  | Non_positive_physical_row_limit value ->
      Printf.sprintf "trajectory physical-row scan limit must be positive: %d"
        value
  | Non_positive_byte_limit value ->
      Printf.sprintf "trajectory byte scan limit must be positive: %Ld" value

(* One read request may inspect at most this physical store window. These are
   transport/I/O page bounds, not Keeper behavior, recurrence, cost, token, or
   turn gates. Keep the two dimensions independent: deriving either from the
   requested canonical-entry count would make non-entry density a heuristic. *)
let standard_trajectory_scan_limits =
  { max_physical_rows = 4_096; max_bytes = 16_777_216L }

type trajectory_scan_stop =
  | Reached_snapshot_start
  | Reached_entry_limit
  | Reached_physical_row_limit
  | Reached_byte_limit
  | Blocked_by_oversized_physical_row
  | Rejected_cursor
  | Read_error

type trajectory_scan_coverage =
  | Scan_complete
  | Scan_partial
  | Scan_blocked

let trajectory_scan_coverage = function
  | Reached_snapshot_start -> Scan_complete
  | Reached_entry_limit
  | Reached_physical_row_limit
  | Reached_byte_limit ->
      Scan_partial
  | Blocked_by_oversized_physical_row | Rejected_cursor | Read_error ->
      Scan_blocked

let trajectory_scan_stop_to_string = function
  | Reached_snapshot_start -> "reached_snapshot_start"
  | Reached_entry_limit -> "reached_entry_limit"
  | Reached_physical_row_limit -> "reached_physical_row_limit"
  | Reached_byte_limit -> "reached_byte_limit"
  | Blocked_by_oversized_physical_row -> "blocked_by_oversized_physical_row"
  | Rejected_cursor -> "rejected_cursor"
  | Read_error -> "read_error"

type trajectory_scan_observation = {
  physical_rows : int;
  bytes_read : int64;
  stop : trajectory_scan_stop;
}

type trajectory_byte_cursor = {
  keeper_name : string;
  trace_id : string;
  snapshot_device : int;
  snapshot_inode : int;
  snapshot_size : int64;
  before_byte : int64;
}

type trajectory_cursor_field =
  | Cursor_schema
  | Cursor_keeper_name
  | Cursor_trace_id
  | Cursor_snapshot_device
  | Cursor_snapshot_inode
  | Cursor_snapshot_size
  | Cursor_before_byte

type trajectory_cursor_decode_error =
  | Cursor_base64_decode_failed
  | Cursor_json_decode_failed
  | Cursor_expected_object
  | Cursor_missing_field of trajectory_cursor_field
  | Cursor_invalid_field of trajectory_cursor_field
  | Cursor_unexpected_field of string
  | Cursor_duplicate_field of string

type trajectory_lines_page = {
  read : trajectory_lines_read_result;
  scan : trajectory_scan_observation;
  next_cursor : trajectory_byte_cursor option;
}

let trajectory_byte_cursor_offset cursor = cursor.before_byte

type persistence_operation =
  | Flush_pending

type persistence_error_cause =
  | Durable_append_rejected of Fs_compat.private_jsonl_append_error
  | Persistence_exception of exn

type persistence_error = {
  operation : persistence_operation;
  path : string;
  cause : persistence_error_cause;
}

exception Persistence_error of persistence_error

let persistence_operation_to_string = function
  | Flush_pending -> "flush_pending"

let persistence_error_to_string error =
  let cause =
    match error.cause with
    | Durable_append_rejected cause ->
        Fs_compat.private_jsonl_append_error_to_string cause
    | Persistence_exception exn -> Printexc.to_string exn
  in
  Printf.sprintf "%s failed for %s: %s"
    (persistence_operation_to_string error.operation)
    error.path
    cause

let () =
  Printexc.register_printer (function
    | Persistence_error error -> Some (persistence_error_to_string error)
    | _ -> None)

(* ================================================================ *)
(* JSON serialization                                               *)
(* ================================================================ *)

let trajectory_contract_version = "v1"
let trajectory_schema = "masc.keeper_trajectory." ^ trajectory_contract_version
let trajectory_cursor_schema =
  "masc.keeper_trajectory_cursor." ^ trajectory_contract_version

let trajectory_cursor_field_to_string = function
  | Cursor_schema -> "schema"
  | Cursor_keeper_name -> "keeper_name"
  | Cursor_trace_id -> "trace_id"
  | Cursor_snapshot_device -> "snapshot_device"
  | Cursor_snapshot_inode -> "snapshot_inode"
  | Cursor_snapshot_size -> "snapshot_size"
  | Cursor_before_byte -> "before_byte"

let trajectory_cursor_decode_error_to_string = function
  | Cursor_base64_decode_failed -> "trajectory cursor is not URI-safe Base64"
  | Cursor_json_decode_failed -> "trajectory cursor payload is not valid JSON"
  | Cursor_expected_object -> "trajectory cursor payload must be an object"
  | Cursor_missing_field field ->
      Printf.sprintf "trajectory cursor is missing %s"
        (trajectory_cursor_field_to_string field)
  | Cursor_invalid_field field ->
      Printf.sprintf "trajectory cursor has invalid %s"
        (trajectory_cursor_field_to_string field)
  | Cursor_unexpected_field field ->
      Printf.sprintf "trajectory cursor has unexpected field %S" field
  | Cursor_duplicate_field field ->
      Printf.sprintf "trajectory cursor has duplicate field %S" field

let trajectory_byte_cursor_to_json cursor =
  `Assoc
    [ "schema", `String trajectory_cursor_schema
    ; "keeper_name", `String cursor.keeper_name
    ; "trace_id", `String cursor.trace_id
    ; "snapshot_device", `String (string_of_int cursor.snapshot_device)
    ; "snapshot_inode", `String (string_of_int cursor.snapshot_inode)
    ; "snapshot_size", `String (Int64.to_string cursor.snapshot_size)
    ; "before_byte", `String (Int64.to_string cursor.before_byte)
    ]

let trajectory_byte_cursor_to_string cursor =
  trajectory_byte_cursor_to_json cursor
  |> Yojson.Safe.to_string
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let trajectory_cursor_fields =
  Set_util.StringSet.of_list
    [ "schema"; "keeper_name"; "trace_id"; "snapshot_device"
    ; "snapshot_inode"; "snapshot_size"; "before_byte"
    ]

let validate_trajectory_cursor_fields fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
        if Set_util.StringSet.mem key seen then
          Error (Cursor_duplicate_field key)
        else if not (Set_util.StringSet.mem key trajectory_cursor_fields) then
          Error (Cursor_unexpected_field key)
        else loop (Set_util.StringSet.add key seen) rest
  in
  loop Set_util.StringSet.empty fields

let trajectory_cursor_required field key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Cursor_missing_field field)

let decode_trajectory_cursor_string field = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (Cursor_invalid_field field)

let decode_trajectory_cursor_int field = function
  | `String value ->
      (match int_of_string_opt value with
       | Some decoded
         when decoded >= 0 && String.equal value (string_of_int decoded) ->
           Ok decoded
       | Some _ | None -> Error (Cursor_invalid_field field))
  | _ -> Error (Cursor_invalid_field field)

let decode_trajectory_cursor_nonnegative_int64 field = function
  | `String value ->
      (match Int64.of_string_opt value with
       | Some decoded
         when decoded >= 0L
              && String.equal value (Int64.to_string decoded) ->
           Ok decoded
       | Some _ | None -> Error (Cursor_invalid_field field))
  | _ -> Error (Cursor_invalid_field field)

let trajectory_byte_cursor_of_json = function
  | `Assoc fields ->
      let ( let* ) = Result.bind in
      let* () = validate_trajectory_cursor_fields fields in
      let* schema_json =
        trajectory_cursor_required Cursor_schema "schema" fields
      in
      let* () =
        match schema_json with
        | `String schema when String.equal schema trajectory_cursor_schema ->
            Ok ()
        | _ -> Error (Cursor_invalid_field Cursor_schema)
      in
      let* keeper_name_json =
        trajectory_cursor_required Cursor_keeper_name "keeper_name" fields
      in
      let* keeper_name =
        decode_trajectory_cursor_string Cursor_keeper_name keeper_name_json
      in
      let* trace_id_json =
        trajectory_cursor_required Cursor_trace_id "trace_id" fields
      in
      let* trace_id =
        decode_trajectory_cursor_string Cursor_trace_id trace_id_json
      in
      let* snapshot_device_json =
        trajectory_cursor_required Cursor_snapshot_device "snapshot_device"
          fields
      in
      let* snapshot_device =
        decode_trajectory_cursor_int Cursor_snapshot_device snapshot_device_json
      in
      let* snapshot_inode_json =
        trajectory_cursor_required Cursor_snapshot_inode "snapshot_inode" fields
      in
      let* snapshot_inode =
        decode_trajectory_cursor_int Cursor_snapshot_inode snapshot_inode_json
      in
      let* snapshot_size_json =
        trajectory_cursor_required Cursor_snapshot_size "snapshot_size" fields
      in
      let* snapshot_size =
        decode_trajectory_cursor_nonnegative_int64 Cursor_snapshot_size
          snapshot_size_json
      in
      let* before_byte_json =
        trajectory_cursor_required Cursor_before_byte "before_byte" fields
      in
      let* before_byte =
        decode_trajectory_cursor_nonnegative_int64 Cursor_before_byte
          before_byte_json
      in
      if before_byte > snapshot_size then
        Error (Cursor_invalid_field Cursor_before_byte)
      else
        Ok
          { keeper_name; trace_id; snapshot_device; snapshot_inode
          ; snapshot_size; before_byte
          }
  | _ -> Error Cursor_expected_object

let trajectory_byte_cursor_of_string encoded =
  let is_uri_safe_base64_character = function
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  if encoded = "" || not (String.for_all is_uri_safe_base64_character encoded)
  then Error Cursor_base64_decode_failed
  else
    match
      Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet encoded
    with
    | Error _ -> Error Cursor_base64_decode_failed
    | Ok payload
      when not
             (String.equal encoded
                (Base64.encode_string ~pad:false
                   ~alphabet:Base64.uri_safe_alphabet payload)) ->
        Error Cursor_base64_decode_failed
    | Ok payload ->
        (match Yojson.Safe.from_string payload with
         | json -> trajectory_byte_cursor_of_json json
         | exception Yojson.Json_error _ -> Error Cursor_json_decode_failed)

let outcome_to_json = function
  | Completed -> `String "completed"
  | Failed msg -> `Assoc [("status", `String "failed"); ("reason", `String msg)]
  | Input_required -> `String "input_required"
  | Cancelled -> `String "cancelled"

let outcome_to_string = function
  | Completed -> "completed"
  | Failed msg -> Printf.sprintf "failed: %s" msg
  | Input_required -> "input_required"
  | Cancelled -> "cancelled"

let tool_call_outcome_to_json = function
  | Tool_succeeded output ->
      `Assoc
        [ ("status", `String "succeeded")
        ; ("output", `String output)
        ]
  | Tool_failed error ->
      `Assoc
        [ ("status", `String "failed")
        ; ("error", `String error)
        ]

let schedule_to_json (schedule : Agent_sdk.Tool.schedule) =
  `Assoc
    [ ("planned_index", `Int schedule.planned_index)
    ; ("batch_index", `Int schedule.batch_index)
    ; ("batch_size", `Int schedule.batch_size)
    ; ( "execution_mode"
      , Agent_sdk.Tool.execution_mode_to_yojson schedule.execution_mode )
    ]

let entry_to_json (e : tool_call_entry) : Yojson.Safe.t =
  `Assoc
    ([
       ("schema", `String trajectory_schema);
       ("type", `String "tool_call");
       ("ts", `Float e.ts);
       ("ts_iso", `String e.ts_iso);
       ("keeper_turn_id", `Int e.keeper_turn_id);
       ("oas_turn", `Int e.oas_turn);
       ("schedule", schedule_to_json e.schedule);
       ("tool_use_id", `String e.tool_use_id);
       ("tool_name", `String e.tool_name);
       ("args", `Assoc e.arguments);
       ("outcome", tool_call_outcome_to_json e.outcome);
       ("duration_ms", `Int e.duration_ms);
       ("execution_id", Ids.Execution_id.to_yojson e.execution_id);
     ]
    )

let thinking_entry_to_json (e : thinking_entry) : Yojson.Safe.t =
  `Assoc [
    ("schema", `String trajectory_schema);
    ("type", `String "thinking");
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("keeper_turn_id", `Int e.keeper_turn_id);
    ("oas_turn", `Int e.oas_turn);
    ("block_index", `Int e.block_index);
    ("block", Agent_sdk.Api.content_block_to_json e.block);
  ]

let trajectory_line_to_json = function
  | Tool_call e -> entry_to_json e
  | Thinking e -> thinking_entry_to_json e

let jsonl_suffix jsons =
  let buffer = Buffer.create 4096 in
  List.iter
    (fun json ->
       Buffer.add_string buffer (Yojson.Safe.to_string json);
       Buffer.add_char buffer '\n')
    jsons;
  Buffer.contents buffer

let append_jsonl_rows ~operation ~path jsons =
  try
    match
      Fs_compat.append_private_jsonl_durable_locked_result path
        (jsonl_suffix jsons)
    with
    | Ok () -> ()
    | Error cause ->
        raise
          (Persistence_error
             { operation; path; cause = Durable_append_rejected cause })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Persistence_error _ as exn -> raise exn
  | exn ->
      raise
        (Persistence_error
           { operation; path; cause = Persistence_exception exn })

let trajectory_to_json (t : trajectory) : Yojson.Safe.t =
  `Assoc [
    ("schema", `String trajectory_schema);
    ("keeper_name", `String t.keeper_name);
    ("trace_id", `String t.trace_id);
    ("keeper_turn_id", `Int t.keeper_turn_id);
    ("generation", `Int t.generation);
    ("started_at", `Float t.started_at);
    ("ended_at", `Float t.ended_at);
    ("observed_oas_turn_count", `Int t.observed_oas_turn_count);
    ("total_tool_calls", `Int t.total_tool_calls);
    ("outcome", outcome_to_json t.outcome);
  ]

let invalid_entry_counts_to_json (counts : invalid_entry_counts) =
  `Assoc
    [ ("missing_required_field", `Int counts.missing_required_field)
    ; ("invalid_field", `Int counts.invalid_field)
    ; ("unexpected_field", `Int counts.unexpected_field)
    ; ("duplicate_field", `Int counts.duplicate_field)
    ; ("unsupported_row_type", `Int counts.unsupported_row_type)
    ; ("malformed_json", `Int counts.malformed_json)
    ]

let entry_decode_summary_to_json (summary : entry_decode_summary) =
  `Assoc
    [ ("invalid_entry_count", `Int summary.invalid_entry_count)
    ; ("invalid_reasons", invalid_entry_counts_to_json summary.invalid_reasons)
    ]

let trajectory_line_decode_summary_to_json
    (summary : trajectory_line_decode_summary) =
  `Assoc
    [ ("tool_call_count", `Int summary.tool_call_count)
    ; ("thinking_count", `Int summary.thinking_count)
    ; ("skipped_summary_count", `Int summary.skipped_summary_count)
    ; ("invalid_line_count", `Int summary.invalid_line_count)
    ; ("invalid_reasons", invalid_entry_counts_to_json summary.invalid_reasons)
    ]

let trajectory_read_errors_to_json errors =
  `List
    (List.map
       (fun (error : trajectory_read_error) ->
          `Assoc
            [ ("path", `String error.path)
            ; ("message", `String error.message)
            ])
       errors)

(* ================================================================ *)
(* JSON deserialization                                             *)
(* ================================================================ *)
(* Decoders live next to the serializers above and are shared by the read
   paths. *)

let required_member field key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> Ok value
  | None -> Error (Missing_required_field field)

let decode_finite_number field = function
  | `Float value when Float.is_finite value -> Ok value
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (Invalid_field field)

let decode_non_blank_string field = function
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error (Invalid_field field)

let decode_string field = function
  | `String value -> Ok value
  | _ -> Error (Invalid_field field)

let decode_nonnegative_int field = function
  | `Int value when value >= 0 -> Ok value
  | _ -> Error (Invalid_field field)

let decode_positive_int field = function
  | `Int value when value > 0 -> Ok value
  | _ -> Error (Invalid_field field)

let decode_arguments = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Invalid_field Arguments)

let decode_schema json =
  let ( let* ) = Result.bind in
  let* schema_json = required_member Schema "schema" json in
  match schema_json with
  | `String schema when String.equal schema trajectory_schema -> Ok ()
  | _ -> Error (Invalid_field Schema)

let decode_tool_call_outcome json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc [ ("status", `String "succeeded"); ("output", output_json) ]
  | `Assoc [ ("output", output_json); ("status", `String "succeeded") ] ->
      let* output = decode_string Tool_outcome output_json in
      Ok (Tool_succeeded output)
  | `Assoc [ ("status", `String "failed"); ("error", error_json) ]
  | `Assoc [ ("error", error_json); ("status", `String "failed") ] ->
      let* error = decode_non_blank_string Tool_outcome error_json in
      Ok (Tool_failed error)
  | _ -> Error (Invalid_field Tool_outcome)

let validate_object_fields ~allowed = function
  | `Assoc fields ->
      let rec loop seen = function
        | [] -> Ok ()
        | (key, _) :: rest ->
            if Set_util.StringSet.mem key seen then Error (Duplicate_field key)
            else if not (Set_util.StringSet.mem key allowed) then
              Error (Unexpected_field key)
            else loop (Set_util.StringSet.add key seen) rest
      in
      loop Set_util.StringSet.empty fields
  | _ -> Error (Invalid_field Row_type)

let schedule_fields =
  Set_util.StringSet.of_list
    [ "planned_index"; "batch_index"; "batch_size"; "execution_mode" ]

let decode_schedule json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:schedule_fields json in
  let* planned_index_json = required_member Planned_index "planned_index" json in
  let* planned_index = decode_nonnegative_int Planned_index planned_index_json in
  let* batch_index_json = required_member Batch_index "batch_index" json in
  let* batch_index = decode_nonnegative_int Batch_index batch_index_json in
  let* batch_size_json = required_member Batch_size "batch_size" json in
  let* batch_size = decode_positive_int Batch_size batch_size_json in
  let* execution_mode_json =
    required_member Execution_mode "execution_mode" json
  in
  let* execution_mode =
    match Agent_sdk.Tool.execution_mode_of_yojson execution_mode_json with
    | Ok mode -> Ok mode
    | Error _ -> Error (Invalid_field Execution_mode)
  in
  Ok
    { Agent_sdk.Tool.planned_index = planned_index
    ; batch_index
    ; batch_size
    ; execution_mode
    }

let tool_call_fields =
  Set_util.StringSet.of_list
    [ "schema"; "type"; "ts"; "ts_iso"; "keeper_turn_id"; "oas_turn"
    ; "schedule"; "tool_use_id"; "tool_name"; "args"; "outcome"
    ; "duration_ms"; "execution_id"
    ]

let thinking_fields =
  Set_util.StringSet.of_list
    [ "schema"; "type"; "ts"; "ts_iso"; "keeper_turn_id"; "oas_turn"
    ; "block_index"; "block"
    ]

let summary_fields =
  Set_util.StringSet.of_list
    [ "schema"; "type"; "keeper_name"; "trace_id"; "generation"
    ; "keeper_turn_id"; "observed_oas_turn_count"; "total_tool_calls"
    ; "outcome"; "started_at"; "ended_at"
    ]

let decode_trajectory_outcome = function
  | `String "completed" -> Ok Completed
  | `String "input_required" -> Ok Input_required
  | `String "cancelled" -> Ok Cancelled
  | (`Assoc _ as json) ->
      let ( let* ) = Result.bind in
      let allowed = Set_util.StringSet.of_list [ "status"; "reason" ] in
      let* () = validate_object_fields ~allowed json in
      let* status_json = required_member Trajectory_outcome "status" json in
      let* status = decode_string Trajectory_outcome status_json in
      let* reason_json = required_member Trajectory_outcome "reason" json in
      let* reason = decode_string Trajectory_outcome reason_json in
      (match status with
       | "failed" -> Ok (Failed reason)
       | _ -> Error (Invalid_field Trajectory_outcome))
  | _ -> Error (Invalid_field Trajectory_outcome)

let decode_summary_row json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:summary_fields json in
  let* () = decode_schema json in
  let* row_type_json = required_member Row_type "type" json in
  let* row_type = decode_non_blank_string Row_type row_type_json in
  let* () =
    if String.equal row_type "trajectory_summary" then Ok ()
    else Error (Unsupported_row_type row_type)
  in
  let* keeper_name_json = required_member Keeper_name "keeper_name" json in
  let* _keeper_name = decode_non_blank_string Keeper_name keeper_name_json in
  let* trace_id_json = required_member Trace_id "trace_id" json in
  let* _trace_id = decode_non_blank_string Trace_id trace_id_json in
  let* generation_json = required_member Generation "generation" json in
  let* _generation = decode_nonnegative_int Generation generation_json in
  let* keeper_turn_id_json =
    required_member Keeper_turn_id "keeper_turn_id" json
  in
  let* _keeper_turn_id =
    decode_positive_int Keeper_turn_id keeper_turn_id_json
  in
  let* observed_turns_json =
    required_member Observed_oas_turn_count "observed_oas_turn_count" json
  in
  let* _observed_turns =
    decode_nonnegative_int Observed_oas_turn_count observed_turns_json
  in
  let* tool_calls_json =
    required_member Total_tool_calls "total_tool_calls" json
  in
  let* _tool_calls = decode_nonnegative_int Total_tool_calls tool_calls_json in
  let* outcome_json = required_member Trajectory_outcome "outcome" json in
  let* _outcome = decode_trajectory_outcome outcome_json in
  let* started_at_json = required_member Started_at "started_at" json in
  let* _started_at = decode_finite_number Started_at started_at_json in
  let* ended_at_json = required_member Ended_at "ended_at" json in
  let* _ended_at = decode_finite_number Ended_at ended_at_json in
  Ok ()

let decode_tool_call_entry json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:tool_call_fields json in
  let* () = decode_schema json in
  let* row_type_json = required_member Row_type "type" json in
  let* row_type = decode_non_blank_string Row_type row_type_json in
  let* () =
    if String.equal row_type "tool_call" then Ok ()
    else Error (Unsupported_row_type row_type)
  in
  let* ts_json = required_member Timestamp "ts" json in
  let* ts = decode_finite_number Timestamp ts_json in
  let* ts_iso_json = required_member Timestamp_iso "ts_iso" json in
  let* ts_iso = decode_non_blank_string Timestamp_iso ts_iso_json in
  let* keeper_turn_id_json =
    required_member Keeper_turn_id "keeper_turn_id" json
  in
  let* keeper_turn_id = decode_positive_int Keeper_turn_id keeper_turn_id_json in
  let* oas_turn_json = required_member Oas_turn "oas_turn" json in
  let* oas_turn = decode_nonnegative_int Oas_turn oas_turn_json in
  let* schedule_json = required_member Schedule "schedule" json in
  let* schedule = decode_schedule schedule_json in
  let* tool_use_id_json = required_member Tool_use_id "tool_use_id" json in
  let* tool_use_id = decode_string Tool_use_id tool_use_id_json in
  let* tool_name_json = required_member Tool_name "tool_name" json in
  let* tool_name = decode_non_blank_string Tool_name tool_name_json in
  let* args_value = required_member Arguments "args" json in
  let* arguments = decode_arguments args_value in
  let* outcome_json = required_member Tool_outcome "outcome" json in
  let* outcome = decode_tool_call_outcome outcome_json in
  let* duration_json = required_member Duration_ms "duration_ms" json in
  let* duration_ms = decode_nonnegative_int Duration_ms duration_json in
  let* execution_id_json = required_member Execution_id "execution_id" json in
  let* execution_id =
    match Ids.Execution_id.of_yojson execution_id_json with
    | Ok execution_id -> Ok execution_id
    | Error _ -> Error (Invalid_field Execution_id)
  in
  let invocation =
    Agent_sdk.Tool.Invocation.create ~tool_use_id ~turn:oas_turn ~schedule
  in
  make_tool_call_entry ~ts ~ts_iso ~keeper_turn_id ~invocation ~tool_name
    ~arguments ~outcome ~duration_ms ~execution_id

let decode_thinking_entry json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:thinking_fields json in
  let* () = decode_schema json in
  let* row_type_json = required_member Row_type "type" json in
  let* row_type = decode_non_blank_string Row_type row_type_json in
  let* () =
    if String.equal row_type "thinking" then Ok ()
    else Error (Unsupported_row_type row_type)
  in
  let* ts_json = required_member Timestamp "ts" json in
  let* ts = decode_finite_number Timestamp ts_json in
  let* ts_iso_json = required_member Timestamp_iso "ts_iso" json in
  let* ts_iso = decode_non_blank_string Timestamp_iso ts_iso_json in
  let* keeper_turn_id_json =
    required_member Keeper_turn_id "keeper_turn_id" json
  in
  let* keeper_turn_id = decode_positive_int Keeper_turn_id keeper_turn_id_json in
  let* oas_turn_json = required_member Oas_turn "oas_turn" json in
  let* oas_turn = decode_nonnegative_int Oas_turn oas_turn_json in
  let* block_index_json = required_member Block_index "block_index" json in
  let* block_index = decode_nonnegative_int Block_index block_index_json in
  let* block_json = required_member Thinking_block "block" json in
  let* block =
    match Agent_sdk.Api.content_block_of_json block_json with
    | Some
        ((Agent_sdk.Types.Thinking _
         | Agent_sdk.Types.ReasoningDetails _
         | Agent_sdk.Types.RedactedThinking _) as block) ->
        if Agent_sdk.Api.content_block_to_json block = block_json
        then Ok block
        else Error (Invalid_field Thinking_block)
    | Some
        (Agent_sdk.Types.Text _
        | Agent_sdk.Types.ToolUse _
        | Agent_sdk.Types.ToolResult _
        | Agent_sdk.Types.Image _
        | Agent_sdk.Types.Document _
        | Agent_sdk.Types.Audio _)
    | None ->
        Error (Invalid_field Thinking_block)
  in
  make_thinking_entry ~ts ~ts_iso ~keeper_turn_id ~oas_turn ~block_index ~block

let tool_call_entry_of_json (json : Yojson.Safe.t) : tool_call_entry_decode =
  match Json_util.assoc_member_opt "type" json with
  | Some (`String "trajectory_summary") ->
      (match decode_summary_row json with
       | Ok () -> Non_entry_row
       | Error error -> Invalid_entry error)
  | Some (`String "thinking") ->
      (match decode_thinking_entry json with
       | Ok _ -> Non_entry_row
       | Error error -> Invalid_entry error)
  | Some (`String "tool_call") ->
      (match decode_tool_call_entry json with
       | Ok entry -> Decoded_entry entry
       | Error error -> Invalid_entry error)
  | Some (`String row_type) -> Invalid_entry (Unsupported_row_type row_type)
  | Some _ -> Invalid_entry (Invalid_field Row_type)
  | None -> Invalid_entry (Missing_required_field Row_type)

let empty_invalid_entry_counts : invalid_entry_counts =
  {
    missing_required_field = 0;
    invalid_field = 0;
    unexpected_field = 0;
    duplicate_field = 0;
    unsupported_row_type = 0;
    malformed_json = 0;
  }

let empty_entry_decode_summary : entry_decode_summary =
  {
    invalid_entry_count = 0;
    invalid_reasons = empty_invalid_entry_counts;
  }

type decode_accumulator = {
  mutable invalid_entry_count : int;
  mutable missing_required_field : int;
  mutable invalid_field : int;
  mutable unexpected_field : int;
  mutable duplicate_field : int;
  mutable unsupported_row_type : int;
  mutable malformed_json : int;
}

let create_decode_accumulator () =
  {
    invalid_entry_count = 0;
    missing_required_field = 0;
    invalid_field = 0;
    unexpected_field = 0;
    duplicate_field = 0;
    unsupported_row_type = 0;
    malformed_json = 0;
  }

let decode_accumulator_snapshot accumulator : entry_decode_summary =
  {
    invalid_entry_count = accumulator.invalid_entry_count;
    invalid_reasons =
      {
        missing_required_field = accumulator.missing_required_field;
        invalid_field = accumulator.invalid_field;
        unexpected_field = accumulator.unexpected_field;
        duplicate_field = accumulator.duplicate_field;
        unsupported_row_type = accumulator.unsupported_row_type;
        malformed_json = accumulator.malformed_json;
      };
  }

let record_invalid_entry accumulator error =
  accumulator.invalid_entry_count <- accumulator.invalid_entry_count + 1;
  match error with
  | Missing_required_field _ ->
      accumulator.missing_required_field <-
        accumulator.missing_required_field + 1
  | Invalid_field _ -> accumulator.invalid_field <- accumulator.invalid_field + 1
  | Unexpected_field _ ->
      accumulator.unexpected_field <- accumulator.unexpected_field + 1
  | Duplicate_field _ ->
      accumulator.duplicate_field <- accumulator.duplicate_field + 1
  | Unsupported_row_type _ ->
      accumulator.unsupported_row_type <- accumulator.unsupported_row_type + 1
  | Malformed_json -> accumulator.malformed_json <- accumulator.malformed_json + 1

(** Single definition of "this tool call counts as a failure" for dashboard
    aggregation. *)
let entry_is_failure (e : tool_call_entry) : bool =
  match e.outcome with
  | Tool_succeeded _ -> false
  | Tool_failed _ -> true

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let trajectories_dir (masc_root : string) (keeper_name : string) : string =
  let trajectory_store =
    Common.keeper_runtime_store_dirname Common.Keeper_trajectories
  in
  Filename.concat
    (Filename.concat
       (Filename.concat masc_root Common.keepers_runtime_dirname)
       keeper_name)
    (Filename.concat trajectory_store trajectory_contract_version)

let trajectory_path (masc_root : string) (keeper_name : string) (trace_id : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name)
    (Printf.sprintf "%s.jsonl" trace_id)

(* All trajectory rows cross [append_jsonl_rows], which delegates to the
   private, durable, per-path locked append boundary in [Fs_compat]. *)

let summary_to_json (traj : trajectory) =
  `Assoc [
    ("schema", `String trajectory_schema);
    ("type", `String "trajectory_summary");
    ("keeper_name", `String traj.keeper_name);
    ("trace_id", `String traj.trace_id);
    ("generation", `Int traj.generation);
    ("keeper_turn_id", `Int traj.keeper_turn_id);
    ("observed_oas_turn_count", `Int traj.observed_oas_turn_count);
    ("total_tool_calls", `Int traj.total_tool_calls);
    ("outcome", outcome_to_json traj.outcome);
    ("started_at", `Float traj.started_at);
    ("ended_at", `Float traj.ended_at);
  ]

(* ================================================================ *)
(* Trajectory accumulator (mutable, per-session)                    *)
(* ================================================================ *)

type pending_entry = {
  pe_json : Yojson.Safe.t;
}

module Turn_set = Set.Make (Int)

type accumulator = {
  mutable tool_call_count : int;
  mutable observed_oas_turns : Turn_set.t;
  keeper_name : string;
  trace_id : string;
  keeper_turn_id : int;
  generation : int;
  started_at : float;
  masc_root : string;
  pending_queue : pending_entry Queue.t;
  pending_mu : Stdlib.Mutex.t;
  flush_mu : Stdlib.Mutex.t;
  mutable last_flush : float;
  on_flush_error : (exn -> unit) option;
  mutable background_flush_in_flight : bool;
  mutable finalized : bool;
}

(* Global registry of active accumulators for batch flush.
   The background flush fiber iterates this to drain pending queues. *)
let active_accumulators :
    (string * string * string * int, accumulator) Hashtbl.t =
  Hashtbl.create 16
let active_acc_mu = Stdlib.Mutex.create ()

type accumulator_registration_error =
  | Active_accumulator_exists of
      { masc_root : string
      ; keeper_name : string
      ; trace_id : string
      ; keeper_turn_id : int
      }

exception Accumulator_registration_error of accumulator_registration_error

let accumulator_registration_error_to_string = function
  | Active_accumulator_exists
      { masc_root; keeper_name; trace_id; keeper_turn_id } ->
      Printf.sprintf
        "active trajectory accumulator already exists (root=%s keeper=%s trace=%s keeper_turn_id=%d)"
        masc_root keeper_name trace_id keeper_turn_id

let () =
  Printexc.register_printer (function
    | Accumulator_registration_error error ->
        Some (accumulator_registration_error_to_string error)
    | _ -> None)

let register_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    let key =
      acc.masc_root, acc.keeper_name, acc.trace_id, acc.keeper_turn_id
    in
    if Hashtbl.mem active_accumulators key then
      raise
        (Accumulator_registration_error
           (Active_accumulator_exists
              { masc_root = acc.masc_root
              ; keeper_name = acc.keeper_name
              ; trace_id = acc.trace_id
              ; keeper_turn_id = acc.keeper_turn_id
              }));
    Hashtbl.add active_accumulators key acc)

let unregister_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.remove active_accumulators
      (acc.masc_root, acc.keeper_name, acc.trace_id, acc.keeper_turn_id))

let create_accumulator ?on_flush_error ~masc_root ~keeper_name ~trace_id
    ~keeper_turn_id ~generation () : accumulator =
  if keeper_turn_id <= 0 then
    invalid_arg "trajectory keeper_turn_id must be positive";
  let acc = {
    tool_call_count = 0;
    observed_oas_turns = Turn_set.empty;
    keeper_name;
    trace_id;
    keeper_turn_id;
    generation;
    started_at = Time_compat.now ();
    masc_root;
    pending_queue = Queue.create ();
    pending_mu = Stdlib.Mutex.create ();
    flush_mu = Stdlib.Mutex.create ();
    last_flush = 0.0;
    on_flush_error;
    background_flush_in_flight = false;
    finalized = false;
  } in
  register_accumulator acc;
  acc

let accumulator_masc_root (acc : accumulator) = acc.masc_root
let accumulator_keeper_name (acc : accumulator) = acc.keeper_name
let accumulator_trace_id (acc : accumulator) = acc.trace_id
let accumulator_keeper_turn_id (acc : accumulator) = acc.keeper_turn_id

let record_entry (acc : accumulator) (entry : tool_call_entry) : unit =
  let json = entry_to_json entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    if acc.finalized then
      invalid_arg "cannot record a trajectory entry after finalization";
    if entry.keeper_turn_id <> acc.keeper_turn_id then
      invalid_arg "trajectory Tool row belongs to a different Keeper turn";
    acc.tool_call_count <- acc.tool_call_count + 1;
    acc.observed_oas_turns <-
      Turn_set.add entry.oas_turn acc.observed_oas_turns;
    Queue.push { pe_json = json } acc.pending_queue)

let record_thinking (acc : accumulator) (entry : thinking_entry) : unit =
  let json = thinking_entry_to_json entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    if acc.finalized then
      invalid_arg "cannot record a Thinking entry after finalization";
    if entry.keeper_turn_id <> acc.keeper_turn_id then
      invalid_arg "trajectory Thinking row belongs to a different Keeper turn";
    acc.observed_oas_turns <-
      Turn_set.add entry.oas_turn acc.observed_oas_turns;
    Queue.push { pe_json = json } acc.pending_queue)

(** Drain the pending queue and write all entries in a single batch.
    [flush_mu] serializes durable commits per Keeper lane while [pending_mu]
    remains available to producers that enqueue during I/O. *)
let flush_pending (acc : accumulator) : unit =
  Stdlib.Mutex.protect acc.flush_mu (fun () ->
    let entries_to_flush =
      Stdlib.Mutex.protect acc.pending_mu (fun () ->
        if Queue.is_empty acc.pending_queue then []
        else
          let items =
            Queue.fold (fun items entry -> entry :: items) [] acc.pending_queue
          in
          Queue.clear acc.pending_queue;
          List.rev items)
    in
    match entries_to_flush with
    | [] -> ()
    | _ ->
      (try
         let dir = trajectories_dir acc.masc_root acc.keeper_name in
         Fs_compat.mkdir_p dir;
         let path = trajectory_path acc.masc_root acc.keeper_name acc.trace_id in
         let jsons = List.map (fun entry -> entry.pe_json) entries_to_flush in
         append_jsonl_rows ~operation:Flush_pending ~path jsons;
         let unregister =
           Stdlib.Mutex.protect acc.pending_mu (fun () ->
             acc.last_flush <- Time_compat.now ();
             acc.finalized && Queue.is_empty acc.pending_queue)
         in
         if unregister then unregister_accumulator acc
       with
       | exn ->
         let report =
           Stdlib.Mutex.protect acc.pending_mu (fun () ->
             let restored = Queue.create () in
             List.iter (fun entry -> Queue.push entry restored)
               entries_to_flush;
             Queue.iter (fun entry -> Queue.push entry restored)
               acc.pending_queue;
             Queue.clear acc.pending_queue;
             Queue.transfer restored acc.pending_queue;
             acc.on_flush_error)
         in
         (match exn with
          | Eio.Cancel.Cancelled _ -> raise exn
          | _ -> ());
         let persistence_exn =
           match exn with
           | Persistence_error _ -> exn
           | _ ->
               Persistence_error
                 { operation = Flush_pending
                 ; path =
                     trajectory_path acc.masc_root acc.keeper_name acc.trace_id
                 ; cause = Persistence_exception exn
                 }
         in
         Log.Keeper.error "Failed to flush trajectory batch for %s: %s"
           acc.trace_id (Printexc.to_string persistence_exn);
         (match report with
          | None -> ()
          | Some report ->
              try report persistence_exn with
              | Eio.Cancel.Cancelled _ as cancel -> raise cancel
              | report_exn ->
                  Log.Keeper.warn
                    "Failed to report trajectory flush error for %s: %s"
                    acc.trace_id
                    (Printexc.to_string report_exn));
         raise persistence_exn))

(** Schedule pending entries for all active accumulators without joining lane
    completion. The per-lane claim is released after success, failure, or
    cancellation; failed rows themselves remain queued by [flush_pending]. *)
let flush_all_pending ~(sw : Eio.Switch.t) : unit =
  let accs =
    Stdlib.Mutex.protect active_acc_mu (fun () ->
      Hashtbl.fold (fun _ acc accs -> acc :: accs) active_accumulators [])
  in
  let claim_lane acc =
    Stdlib.Mutex.protect acc.pending_mu (fun () ->
      if acc.background_flush_in_flight || Queue.is_empty acc.pending_queue
      then false
      else begin
        acc.background_flush_in_flight <- true;
        true
      end)
  in
  let release_lane acc =
    Stdlib.Mutex.protect acc.pending_mu (fun () ->
      acc.background_flush_in_flight <- false)
  in
  let flush_lane acc =
    Fun.protect
      ~finally:(fun () -> release_lane acc)
      (fun () ->
        Domain_pool_ref.submit_io_or_inline (fun () ->
          try flush_pending acc with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | Persistence_error error ->
            Log.Keeper.error ~keeper_name:acc.keeper_name
              "trajectory background flush remains pending: %s"
              (persistence_error_to_string error)
          | exn ->
            Log.Keeper.error ~keeper_name:acc.keeper_name
              "trajectory background flush raised: %s"
              (Printexc.to_string exn)))
  in
  List.iter
    (fun acc ->
      if claim_lane acc then
        try Eio.Fiber.fork ~sw (fun () -> flush_lane acc) with
        | Eio.Cancel.Cancelled _ as exn ->
          release_lane acc;
          raise exn
        | exn ->
          release_lane acc;
          Log.Keeper.error ~keeper_name:acc.keeper_name
            "trajectory background flush scheduling failed: %s"
            (Printexc.to_string exn))
    accs

let finalize (acc : accumulator) (outcome : trajectory_outcome) : trajectory =
  let traj =
    Stdlib.Mutex.protect acc.pending_mu (fun () ->
    if acc.finalized then invalid_arg "trajectory accumulator already finalized";
    let traj = {
      keeper_name = acc.keeper_name;
      trace_id = acc.trace_id;
      keeper_turn_id = acc.keeper_turn_id;
      generation = acc.generation;
      started_at = acc.started_at;
      ended_at = Time_compat.now ();
      observed_oas_turn_count = Turn_set.cardinal acc.observed_oas_turns;
      total_tool_calls = acc.tool_call_count;
      outcome;
    } in
    acc.finalized <- true;
    Queue.push { pe_json = summary_to_json traj } acc.pending_queue;
    traj)
  in
  (* Tool rows and the terminal summary commit together. On failure
     [flush_pending] restores the entire batch and leaves the finalized
     accumulator registered so the background per-Keeper retry can persist it. *)
  flush_pending acc;
  traj

(* ================================================================ *)
(* Tool stats aggregation                                          *)
(* ================================================================ *)

type tool_stat = {
  name : string;
  call_count : int;
  success_count : int;
  failure_count : int;
  avg_duration_ms : int;
  p95_duration_ms : int;
  max_duration_ms : int;
  last_used_at : string;
}

type hourly_bucket = {
  hour : string;
  call_count : int;
  error_count : int;
}

(** Compute p95 from a sorted int array. *)
let p95_of_sorted (durations : int array) : int =
  let n = Array.length durations in
  if n = 0 then 0
  else
    let idx = min (n - 1) (int_of_float (Float.round (float_of_int n *. 0.95))) in
    durations.(idx)

let aggregate_tool_stats (entries : tool_call_entry list) : tool_stat list =
  let tbl : (string, int list * int * int * float * string) Hashtbl.t =
    Hashtbl.create 32
  in
  List.iter (fun (e : tool_call_entry) ->
    let is_failure = entry_is_failure e in
    match Hashtbl.find_opt tbl e.tool_name with
    | None ->
      let succ = if is_failure then 0 else 1 in
      let fail = if is_failure then 1 else 0 in
      Hashtbl.replace tbl e.tool_name
        ([e.duration_ms], succ, fail, e.ts, e.ts_iso)
    | Some (durations, succ, fail, max_ts, max_iso) ->
      let succ' = if is_failure then succ else succ + 1 in
      let fail' = if is_failure then fail + 1 else fail in
      let (ts', iso') = if e.ts > max_ts then (e.ts, e.ts_iso) else (max_ts, max_iso) in
      Hashtbl.replace tbl e.tool_name
        (e.duration_ms :: durations, succ', fail', ts', iso')
  ) entries;
  let stats = Hashtbl.fold (fun name (durations, succ, fail, _max_ts, last_iso) acc ->
    let count = succ + fail in
    let total_dur = List.fold_left (+) 0 durations in
    let avg = if count > 0 then total_dur / count else 0 in
    let sorted = Array.of_list durations in
    Array.sort compare sorted;
    let max_d = if Array.length sorted > 0 then sorted.(Array.length sorted - 1) else 0 in
    { name;
      call_count = count;
      success_count = succ;
      failure_count = fail;
      avg_duration_ms = avg;
      p95_duration_ms = p95_of_sorted sorted;
      max_duration_ms = max_d;
      last_used_at = last_iso;
    } :: acc
  ) tbl [] in
  List.sort (fun (a : tool_stat) (b : tool_stat) -> compare b.call_count a.call_count) stats

(** Truncate a Unix timestamp to the start of its UTC hour. *)
let hour_start_iso (ts : float) : string =
  let t = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:00:00Z"
    (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour

let hourly_timeline (entries : tool_call_entry list) : hourly_bucket list =
  let tbl : (string, int * int) Hashtbl.t = Hashtbl.create 24 in
  List.iter (fun (e : tool_call_entry) ->
    let hour = hour_start_iso e.ts in
    let is_err = entry_is_failure e in
    match Hashtbl.find_opt tbl hour with
    | None -> Hashtbl.replace tbl hour (1, if is_err then 1 else 0)
    | Some (c, errs) -> Hashtbl.replace tbl hour (c + 1, errs + (if is_err then 1 else 0))
  ) entries;
  let buckets = Hashtbl.fold (fun hour (call_count, error_count) acc ->
    { hour; call_count; error_count } :: acc
  ) tbl [] in
  List.sort (fun a b -> String.compare a.hour b.hour) buckets

let tool_stat_to_json (s : tool_stat) : Yojson.Safe.t =
  `Assoc [
    ("name", `String s.name);
    ("call_count", `Int s.call_count);
    ("success_count", `Int s.success_count);
    ("failure_count", `Int s.failure_count);
    ("avg_duration_ms", `Int s.avg_duration_ms);
    ("p95_duration_ms", `Int s.p95_duration_ms);
    ("max_duration_ms", `Int s.max_duration_ms);
    ("last_used_at", `String s.last_used_at);
  ]

let hourly_bucket_to_json (b : hourly_bucket) : Yojson.Safe.t =
  `Assoc [
    ("hour", `String b.hour);
    ("call_count", `Int b.call_count);
    ("error_count", `Int b.error_count);
  ]

(** Read all .jsonl trace files for a keeper. Filter entries with ts >= since.
    Scans the keeper's trajectory directory for all trace files one row at a
    time; memory is bounded by the result set plus the largest physical row,
    not by the aggregate trace-file size. *)
let read_entries_since_result ~(masc_root : string) ~(keeper_name : string)
    ~(since : float) : entries_read_result =
  let dir = trajectories_dir masc_root keeper_name in
  let empty_result io_errors =
    { entries = []; decode = empty_entry_decode_summary; io_errors }
  in
  match Fs_compat.path_kind dir with
  | exception Sys_error message -> empty_result [{ path = dir; message }]
  | exception (Unix.Unix_error _ as exn) ->
      empty_result [{ path = dir; message = Printexc.to_string exn }]
  | Fs_compat.Missing -> empty_result []
  | Fs_compat.Other ->
      empty_result
        [{ path = dir; message = "trajectory path is not a directory" }]
  | Fs_compat.Directory ->
    match Fs_compat.read_dir dir with
    | exception Sys_error message ->
        empty_result [{ path = dir; message }]
    | exception (Unix.Unix_error _ as exn) ->
        empty_result [{ path = dir; message = Printexc.to_string exn }]
    | files ->
        let all_entries = ref [] in
        let decode = create_decode_accumulator () in
        let io_errors = ref [] in
        let row_may_be_in_window json =
          match Json_util.assoc_member_opt "ts" json with
          | Some (`Float value) -> value >= since
          | Some (`Int value) -> Float.of_int value >= since
          | _ -> true
        in
        List.iter
          (fun fname ->
             if Filename.check_suffix fname ".jsonl" then
               let path = Filename.concat dir fname in
               let record_io_error message =
                 io_errors := { path; message } :: !io_errors
               in
               let decode_line line =
                 if String.trim line <> "" then
                   match Yojson.Safe.from_string line with
                   | exception
                       (Yojson.Json_error _
                       | Yojson.Safe.Util.Type_error _) ->
                       record_invalid_entry decode Malformed_json
                   | json ->
                       match tool_call_entry_of_json json with
                       | Decoded_entry entry when entry.ts >= since ->
                           all_entries := entry :: !all_entries
                       | Decoded_entry _ | Non_entry_row -> ()
                       | Invalid_entry error when row_may_be_in_window json ->
                           record_invalid_entry decode error
                       | Invalid_entry _ -> ()
               in
               let stream_file () =
                 match open_in_bin path with
                 | exception Sys_error message -> record_io_error message
                 | input ->
                     let input_is_open = ref true in
                     Fun.protect
                       ~finally:(fun () ->
                         if !input_is_open then
                           match close_in input with
                           | () -> ()
                           | exception Sys_error message ->
                               record_io_error message)
                       (fun () ->
                          let rec read () =
                            match input_line input with
                            | line ->
                                decode_line line;
                                read ()
                            | exception End_of_file -> ()
                            | exception Sys_error message ->
                                record_io_error message
                          in
                          read ();
                          let close_result =
                            match close_in input with
                            | () -> None
                            | exception Sys_error message -> Some message
                          in
                          input_is_open := false;
                          Option.iter record_io_error close_result)
               in
               match Fs_compat.exact_path_kind path with
               | exception Sys_error message -> record_io_error message
               | exception (Unix.Unix_error _ as exn) ->
                   record_io_error (Printexc.to_string exn)
               | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
                   stream_file ()
               | Fs_compat.Exact_missing ->
                   record_io_error "trajectory file disappeared during read"
               | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
                   record_io_error "trajectory path is not a regular file")
          files;
        {
          entries =
            List.sort
              (fun (a : tool_call_entry) (b : tool_call_entry) ->
                 compare a.ts b.ts)
              !all_entries;
          decode = decode_accumulator_snapshot decode;
          io_errors = List.rev !io_errors;
        }

(* ================================================================ *)
(* Read trajectory from JSONL (for replay/eval)                     *)
(* ================================================================ *)

let unix_error_detail error function_name argument =
  let operation =
    if argument = "" then function_name
    else Printf.sprintf "%s(%s)" function_name argument
  in
  Printf.sprintf "%s: %s" operation (Unix.error_message error)

let stream_file_lines_result ~path ~init ~fold =
  let io_errors = ref [] in
  let record_io_error message =
    io_errors := { path; message } :: !io_errors
  in
  let unix_error error function_name argument =
    record_io_error (unix_error_detail error function_name argument)
  in
  match open_in_bin path with
  | exception Sys_error message -> init, [{ path; message }]
  | exception Unix.Unix_error (error, function_name, argument) ->
      init,
      [ { path
        ; message = unix_error_detail error function_name argument
        }
      ]
  | input ->
      let close_input () =
        match close_in input with
        | () -> ()
        | exception Sys_error message -> record_io_error message
        | exception Unix.Unix_error (error, function_name, argument) ->
            unix_error error function_name argument
      in
      let folded =
        Fun.protect ~finally:close_input (fun () ->
          let rec read state =
            match input_line input with
            | line -> read (fold state line)
            | exception End_of_file -> state
            | exception Sys_error message ->
                record_io_error message;
                state
            | exception Unix.Unix_error (error, function_name, argument) ->
                unix_error error function_name argument;
                state
          in
          read init)
      in
      folded, List.rev !io_errors

let read_entries_result ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) : entries_read_result =
  let path = trajectory_path masc_root keeper_name trace_id in
  let empty_result io_errors =
    { entries = []; decode = empty_entry_decode_summary; io_errors }
  in
  match Fs_compat.exact_path_kind path with
  | exception Sys_error message -> empty_result [{ path; message }]
  | exception (Unix.Unix_error _ as exn) ->
      empty_result [{ path; message = Printexc.to_string exn }]
  | Fs_compat.Exact_missing -> empty_result []
  | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
      let decode_summary = create_decode_accumulator () in
      let entries_rev, io_errors =
        stream_file_lines_result ~path ~init:[]
          ~fold:(fun entries line ->
            if String.trim line = "" then entries
            else
              match Yojson.Safe.from_string line with
              | exception
                  (Yojson.Json_error _ | Yojson.Safe.Util.Type_error _) ->
                  record_invalid_entry decode_summary Malformed_json;
                  entries
              | json ->
                  match tool_call_entry_of_json json with
                  | Decoded_entry entry -> entry :: entries
                  | Non_entry_row -> entries
                  | Invalid_entry error ->
                      record_invalid_entry decode_summary error;
                      entries)
      in
      {
        entries = List.rev entries_rev;
        decode = decode_accumulator_snapshot decode_summary;
        io_errors;
      }
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      empty_result
        [{ path; message = "trajectory path is not a regular file" }]

type trajectory_line_decode_result =
  | Parsed_line of trajectory_line
  | Skipped_line
  | Invalid_line of entry_decode_error

let trajectory_line_of_json json =
  match Json_util.assoc_member_opt "type" json with
  | Some (`String "trajectory_summary") ->
      (match decode_summary_row json with
       | Ok () -> Skipped_line
       | Error error -> Invalid_line error)
  | Some (`String "thinking") ->
      (match decode_thinking_entry json with
       | Ok entry -> Parsed_line (Thinking entry)
       | Error error -> Invalid_line error)
  | Some (`String "tool_call") ->
      (match tool_call_entry_of_json json with
       | Decoded_entry entry -> Parsed_line (Tool_call entry)
       | Non_entry_row -> Invalid_line (Invalid_field Row_type)
       | Invalid_entry error -> Invalid_line error)
  | Some (`String row_type) -> Invalid_line (Unsupported_row_type row_type)
  | Some _ -> Invalid_line (Invalid_field Row_type)
  | None -> Invalid_line (Missing_required_field Row_type)
;;

type line_decode_accumulator = {
  mutable tool_call_count : int;
  mutable thinking_count : int;
  mutable skipped_summary_count : int;
  invalid : decode_accumulator;
}

let create_line_decode_accumulator () =
  {
    tool_call_count = 0;
    thinking_count = 0;
    skipped_summary_count = 0;
    invalid = create_decode_accumulator ();
  }

let line_decode_accumulator_snapshot accumulator
    : trajectory_line_decode_summary =
  let invalid = decode_accumulator_snapshot accumulator.invalid in
  {
    tool_call_count = accumulator.tool_call_count;
    thinking_count = accumulator.thinking_count;
    skipped_summary_count = accumulator.skipped_summary_count;
    invalid_line_count = invalid.invalid_entry_count;
    invalid_reasons = invalid.invalid_reasons;
  }

let empty_trajectory_line_decode_summary : trajectory_line_decode_summary =
  {
    tool_call_count = 0;
    thinking_count = 0;
    skipped_summary_count = 0;
    invalid_line_count = 0;
    invalid_reasons = empty_invalid_entry_counts;
  }

let accumulate_trajectory_jsonl_line decode_summary acc line =
  if String.trim line = "" then acc
  else
    let decode =
      try Yojson.Safe.from_string line |> trajectory_line_of_json with
      | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
          Invalid_line Malformed_json
    in
    match decode with
    | Parsed_line (Tool_call _ as parsed) ->
        decode_summary.tool_call_count <- decode_summary.tool_call_count + 1;
        parsed :: acc
    | Parsed_line (Thinking _ as parsed) ->
        decode_summary.thinking_count <- decode_summary.thinking_count + 1;
        parsed :: acc
    | Skipped_line ->
        decode_summary.skipped_summary_count <-
          decode_summary.skipped_summary_count + 1;
        acc
    | Invalid_line error ->
        record_invalid_entry decode_summary.invalid error;
        acc

let trajectory_lines_of_jsonl_lines lines =
  let decode_summary = create_line_decode_accumulator () in
  let lines_rev =
    List.fold_left
      (accumulate_trajectory_jsonl_line decode_summary)
      []
      lines
  in
  {
    lines = List.rev lines_rev;
    line_decode = line_decode_accumulator_snapshot decode_summary;
    io_errors = [];
  }
;;

(** Read all trajectory lines including thinking entries. *)
let read_all_lines_result ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) : trajectory_lines_read_result =
  let path = trajectory_path masc_root keeper_name trace_id in
  let empty_result io_errors =
    {
      lines = [];
      line_decode = empty_trajectory_line_decode_summary;
      io_errors;
    }
  in
  match Fs_compat.exact_path_kind path with
  | exception Sys_error message -> empty_result [{ path; message }]
  | exception (Unix.Unix_error _ as exn) ->
      empty_result [{ path; message = Printexc.to_string exn }]
  | Fs_compat.Exact_missing -> empty_result []
  | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
      let decode_summary = create_line_decode_accumulator () in
      let lines_rev, io_errors =
        stream_file_lines_result ~path ~init:[]
          ~fold:(accumulate_trajectory_jsonl_line decode_summary)
      in
      {
        lines = List.rev lines_rev;
        line_decode = line_decode_accumulator_snapshot decode_summary;
        io_errors;
      }
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      empty_result
        [{ path; message = "trajectory path is not a regular file" }]

type backward_line_control =
  | Continue_backward
  | Stop_before of int64 * trajectory_scan_stop

let trajectory_file_identity_matches
    (left : Unix.LargeFile.stats)
    (right : Unix.LargeFile.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino

let read_exact_at descriptor ~position length =
  let bytes = Bytes.create length in
  match Unix.LargeFile.lseek descriptor position Unix.SEEK_SET with
  | exception Unix.Unix_error (error, function_name, argument) ->
      Error (unix_error_detail error function_name argument, 0)
  | actual_position
    when actual_position <> position ->
      Error ("trajectory seek returned a different byte position", 0)
  | _ ->
      let rec read offset =
        if offset = length then Ok bytes
        else
          match Unix.read descriptor bytes offset (length - offset) with
          | 0 ->
              Error
                ( "trajectory file became shorter while reading its snapshot"
                , offset )
          | count -> read (offset + count)
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> read offset
          | exception Unix.Unix_error (error, function_name, argument) ->
              Error
                (unix_error_detail error function_name argument, offset)
      in
      read 0

let decode_backward_line decode_summary lines_rev entry_count ~max_entries line =
  if String.trim line = "" then false
  else
    let decoded =
      match Yojson.Safe.from_string line with
      | json -> trajectory_line_of_json json
      | exception Yojson.Json_error _ -> Invalid_line Malformed_json
      | exception Yojson.Safe.Util.Type_error _ ->
          Invalid_line Malformed_json
    in
    match decoded with
    | Parsed_line (Tool_call _ as parsed) ->
        decode_summary.tool_call_count <- decode_summary.tool_call_count + 1;
        lines_rev := parsed :: !lines_rev;
        incr entry_count;
        !entry_count = max_entries
    | Parsed_line (Thinking _ as parsed) ->
        decode_summary.thinking_count <- decode_summary.thinking_count + 1;
        lines_rev := parsed :: !lines_rev;
        incr entry_count;
        !entry_count = max_entries
    | Skipped_line ->
        decode_summary.skipped_summary_count <-
          decode_summary.skipped_summary_count + 1;
        false
    | Invalid_line error ->
        record_invalid_entry decode_summary.invalid error;
        false

let scan_trajectory_snapshot_backward descriptor ~keeper_name ~trace_id
    ~snapshot_device ~snapshot_inode ~snapshot_size ~before_byte ~max_entries
    ~initial_bytes_read ~(scan_limits : trajectory_scan_limits) =
  let decode_summary = create_line_decode_accumulator () in
  let lines_rev = ref [] in
  let entry_count = ref 0 in
  let physical_rows = ref 0 in
  let bytes_read = ref initial_bytes_read in
  let oldest_complete_boundary = ref before_byte in
  let add_fragment bytes offset length fragments =
    if length = 0 then fragments
    else Bytes.sub_string bytes offset length :: fragments
  in
  let process_line ~line_start fragments =
    (* A page starts at EOF or immediately after a newline. The first empty
       segment at exactly that boundary is a separator sentinel, not a second
       physical row. Empty segments at any older boundary are real blank rows
       and consume the physical-row transport allowance. *)
    if line_start = before_byte && fragments = [] then Continue_backward
    else begin
      incr physical_rows;
      let reached_entry_limit =
        decode_backward_line decode_summary lines_rev entry_count ~max_entries
          (String.concat "" fragments)
      in
      oldest_complete_boundary := line_start;
      if line_start = 0L then
        Stop_before (0L, Reached_snapshot_start)
      else if reached_entry_limit then
        Stop_before (line_start, Reached_entry_limit)
      else if !physical_rows = scan_limits.max_physical_rows then
        Stop_before (line_start, Reached_physical_row_limit)
      else Continue_backward
    end
  in
  let byte_limit_stop () =
    if !oldest_complete_boundary < before_byte then
      Ok (!oldest_complete_boundary, Reached_byte_limit)
    else Ok (before_byte, Blocked_by_oversized_physical_row)
  in
  let rec scan_chunks position fragments =
    if position = 0L then
      if before_byte = 0L && fragments = [] then
        Ok (0L, Reached_snapshot_start)
      else
        (match process_line ~line_start:0L fragments with
         | Continue_backward | Stop_before (0L, _) ->
             Ok (0L, Reached_snapshot_start)
         | Stop_before (before, stop) -> Ok (before, stop))
    else if !bytes_read = scan_limits.max_bytes then byte_limit_stop ()
    else
      let remaining_bytes = Int64.sub scan_limits.max_bytes !bytes_read in
      let read_length =
        Int64.to_int
          (Int64.min
             (Int64.of_int Sys.io_buffer_size)
             (Int64.min position remaining_bytes))
      in
      let read_start = Int64.sub position (Int64.of_int read_length) in
      match read_exact_at descriptor ~position:read_start read_length with
      | Error (message, consumed) ->
          bytes_read := Int64.add !bytes_read (Int64.of_int consumed);
          Error message
      | Ok bytes ->
          bytes_read := Int64.add !bytes_read (Int64.of_int read_length);
          let rec scan_chunk index segment_end fragments =
            if index < 0 then
              let fragments =
                add_fragment bytes 0 segment_end fragments
              in
              scan_chunks read_start fragments
            else if Bytes.get bytes index = '\n' then
              let fragments =
                add_fragment bytes (index + 1) (segment_end - index - 1)
                  fragments
              in
              let line_start =
                Int64.add read_start (Int64.of_int (index + 1))
              in
              (match process_line ~line_start fragments with
               | Stop_before (before, stop) -> Ok (before, stop)
               | Continue_backward -> scan_chunk (index - 1) index [])
            else scan_chunk (index - 1) segment_end fragments
          in
          scan_chunk (read_length - 1) read_length fragments
  in
  match scan_chunks before_byte [] with
  | Error message ->
      Error
        ( message
        , { physical_rows = !physical_rows
          ; bytes_read = !bytes_read
          ; stop = Read_error
          } )
  | Ok (next_before, stop) ->
      let next_cursor =
        match stop with
        | Reached_entry_limit
        | Reached_physical_row_limit
        | Reached_byte_limit
          when next_before > 0L ->
            Some
              { keeper_name; trace_id; snapshot_device; snapshot_inode
              ; snapshot_size; before_byte = next_before
              }
        | Reached_snapshot_start
        | Blocked_by_oversized_physical_row
        | Rejected_cursor
        | Read_error
        | Reached_entry_limit
        | Reached_physical_row_limit
        | Reached_byte_limit ->
            None
      in
      Ok
        {
          read =
            {
              lines = !lines_rev;
              line_decode = line_decode_accumulator_snapshot decode_summary;
              io_errors = [];
            };
          scan = { physical_rows = !physical_rows; bytes_read = !bytes_read; stop };
          next_cursor;
        }

let empty_trajectory_lines_page ~stop io_errors =
  {
    read =
      {
        lines = [];
        line_decode = empty_trajectory_line_decode_summary;
        io_errors;
      };
    scan = { physical_rows = 0; bytes_read = 0L; stop };
    next_cursor = None;
  }

let verify_cursor_newline_boundary descriptor before_byte =
  if before_byte = 0L then Ok 0L
  else
    match read_exact_at descriptor ~position:(Int64.pred before_byte) 1 with
    | Error (message, consumed) -> Error (message, Int64.of_int consumed)
    | Ok byte when Bytes.get byte 0 = '\n' -> Ok 1L
    | Ok _ ->
        Error
          ( "trajectory cursor does not point to a newline boundary"
          , 1L )

let read_recent_lines_page_result
      ~(masc_root : string)
      ~(keeper_name : string)
      ~(trace_id : string)
      ?before
      ~(scan_limits : trajectory_scan_limits)
      ~(max_entries : int)
      ()
  : trajectory_lines_page
  =
  let path = trajectory_path masc_root keeper_name trace_id in
  let storage_errors ?scan ~stop io_errors =
    let page = empty_trajectory_lines_page ~stop io_errors in
    match scan with
    | None -> page
    | Some (observation : trajectory_scan_observation) ->
        { page with scan = { observation with stop } }
  in
  let storage_error ?scan ?(stop = Read_error) message =
    storage_errors ?scan ~stop [{ path; message }]
  in
  if max_entries <= 0 then
    invalid_arg
      "Trajectory.read_recent_lines_page_result: max_entries must be positive"
  else
    match Unix.LargeFile.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        empty_trajectory_lines_page ~stop:Reached_snapshot_start []
    | exception Unix.Unix_error (error, function_name, argument) ->
        storage_error (unix_error_detail error function_name argument)
    | initial_stats when initial_stats.st_kind <> Unix.S_REG ->
        storage_error "trajectory path is not a regular file"
    | initial_stats ->
        (match
           Unix.openfile
             path
             [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ]
             0
         with
         | exception Unix.Unix_error (error, function_name, argument) ->
             storage_error (unix_error_detail error function_name argument)
         | descriptor ->
             let descriptor_is_open = ref true in
             Fun.protect
               ~finally:(fun () ->
                 if !descriptor_is_open then
                   match Unix.close descriptor with
                   | () -> ()
                   | exception
                       Unix.Unix_error (error, function_name, argument) ->
                       Log.Keeper.error
                         "trajectory descriptor close failed for %s after an exception: %s"
                         path
                         (unix_error_detail error function_name argument))
               (fun () ->
             let read_result =
               match Unix.LargeFile.fstat descriptor with
               | exception
                   Unix.Unix_error (error, function_name, argument) ->
                   Error
                     ( Read_error
                     , unix_error_detail error function_name argument
                     , None )
               | opened_stats when opened_stats.st_kind <> Unix.S_REG ->
                   Error
                     ( Read_error
                     , "opened trajectory is not a regular file"
                     , None )
               | opened_stats
                 when not
                        (trajectory_file_identity_matches
                           initial_stats opened_stats) ->
                   Error
                     ( Read_error
                     , "trajectory path identity changed while opening"
                     , None )
               | opened_stats ->
                   let snapshot_size, before_byte, cursor_error,
                       cursor_validation_bytes =
                     match before with
                     | None ->
                         opened_stats.st_size, opened_stats.st_size, None, 0L
                     | Some (cursor : trajectory_byte_cursor)
                       when not (String.equal cursor.keeper_name keeper_name)
                            || not (String.equal cursor.trace_id trace_id) ->
                         cursor.snapshot_size,
                         cursor.before_byte,
                         Some
                           "trajectory cursor belongs to a different keeper or trace",
                         0L
                     | Some (cursor : trajectory_byte_cursor)
                       when cursor.snapshot_device <> opened_stats.st_dev
                            || cursor.snapshot_inode <> opened_stats.st_ino ->
                         cursor.snapshot_size,
                         cursor.before_byte,
                         Some "trajectory cursor belongs to a different file",
                         0L
                     | Some (cursor : trajectory_byte_cursor)
                       when opened_stats.st_size < cursor.snapshot_size ->
                         cursor.snapshot_size,
                         cursor.before_byte,
                         Some
                           "trajectory cursor snapshot was truncated before pagination",
                         0L
                     | Some (cursor : trajectory_byte_cursor)
                       when cursor.before_byte < 0L
                            || cursor.before_byte > cursor.snapshot_size ->
                         cursor.snapshot_size,
                         cursor.before_byte,
                         Some "trajectory cursor has an invalid byte boundary",
                         0L
                     | Some (cursor : trajectory_byte_cursor) ->
                         (match
                            verify_cursor_newline_boundary descriptor
                              cursor.before_byte
                          with
                          | Ok bytes ->
                              cursor.snapshot_size,
                              cursor.before_byte,
                              None,
                              bytes
                          | Error (message, bytes) ->
                              cursor.snapshot_size,
                              cursor.before_byte,
                              Some message,
                              bytes)
                   in
                   (match cursor_error with
                    | Some message ->
                        Error
                          ( Rejected_cursor
                          , message
                          , Some
                              { physical_rows = 0
                              ; bytes_read = cursor_validation_bytes
                              ; stop = Rejected_cursor
                              } )
                    | None ->
                        (match
                           scan_trajectory_snapshot_backward descriptor
                             ~keeper_name ~trace_id
                             ~snapshot_device:opened_stats.st_dev
                             ~snapshot_inode:opened_stats.st_ino ~snapshot_size
                             ~before_byte ~max_entries
                             ~initial_bytes_read:cursor_validation_bytes
                             ~scan_limits
                         with
                         | Ok page -> Ok page
                         | Error (message, scan) ->
                             Error (Read_error, message, Some scan)))
             in
             let verified_result =
               match read_result with
               | Error _ as error -> error
               | Ok page ->
                   (match Unix.LargeFile.fstat descriptor,
                          Unix.LargeFile.lstat path with
                    | opened_now, current_path
                      when trajectory_file_identity_matches
                             opened_now current_path
                           && current_path.st_size
                              >=
                              (match before with
                               | None -> initial_stats.st_size
                               | Some (cursor : trajectory_byte_cursor) ->
                                   cursor.snapshot_size) ->
                        Ok page
                    | _ ->
                        Error
                          ( Read_error
                          , "trajectory path was replaced or truncated while reading"
                          , Some page.scan )
                    | exception
                        Unix.Unix_error (error, function_name, argument) ->
                        Error
                          ( Read_error
                          , unix_error_detail error function_name argument
                          , Some page.scan ))
             in
             let close_error =
               let result =
                 match Unix.close descriptor with
                 | () -> None
                 | exception
                     Unix.Unix_error (error, function_name, argument) ->
                     Some (unix_error_detail error function_name argument)
               in
               descriptor_is_open := false;
               result
             in
             match verified_result, close_error with
             | Error (stop, message, scan), None ->
                 storage_error ?scan ~stop message
             | Error (stop, message, scan), Some close_message ->
                 storage_errors ?scan ~stop
                   [{ path; message }; { path; message = close_message }]
             | Ok page, None -> page
             | Ok page, Some message ->
                 {
                   page with
                   read =
                     {
                       page.read with
                       io_errors = [{ path; message }];
                     };
                 }))
