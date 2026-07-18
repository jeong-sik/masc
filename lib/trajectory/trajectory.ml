(** Trajectory — JSONL-based tool call trajectory logging for Keeper Harness.

    Records exact tool call invocations (pre + post) to enable:
    - Deterministic replay of agent behavior
    - Tool count, result, and latency observation
    - Behavioral evaluation via eval_harness.ml

    Model usage and cost come from OAS inference facts. Tool names are not a
    pricing signal and are never used to estimate cost or control recurrence.

    Each keeper session produces a trajectory file at:
      .masc/trajectories/{keeper_name}/{trace_id}.jsonl

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
  turn : int;                       (** Turn number within session *)
  round : int;                      (** Monotonic Tool round within turn *)
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type enforces the
          JSON object invariant without a second string representation. *)
  outcome : tool_call_outcome;
  duration_ms : int;                (** Wall-clock execution time *)
  execution_id : string;
      (** RFC-0233 canonical join key minted at the dispatch boundary; the
          tool_calls JSONL row for the same execution carries the identical
          value. Plain string here: Trajectory is a dependency-leaf
          persistence record, the typed [Ids.Execution_id.t] lives at the
          mint site. *)
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
  | Row_type
  | Timestamp
  | Timestamp_iso
  | Turn
  | Round
  | Tool_name
  | Arguments
  | Tool_outcome
  | Duration_ms
  | Execution_id
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
  | Row_type -> "row_type"
  | Timestamp -> "timestamp"
  | Timestamp_iso -> "timestamp_iso"
  | Turn -> "turn"
  | Round -> "round"
  | Tool_name -> "tool_name"
  | Arguments -> "arguments"
  | Tool_outcome -> "tool_outcome"
  | Duration_ms -> "duration_ms"
  | Execution_id -> "execution_id"
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

let make_tool_call_entry ~ts ~ts_iso ~turn ~round ~tool_name ~arguments
    ~outcome ~duration_ms ~execution_id =
  let rec validate_argument_keys seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
        if Set_util.StringSet.mem key seen then Error (Duplicate_field key)
        else
          validate_argument_keys (Set_util.StringSet.add key seen) rest
  in
  if not (Float.is_finite ts) then Error (Invalid_field Timestamp)
  else if String.trim ts_iso = "" then Error (Invalid_field Timestamp_iso)
  else if turn < 0 then Error (Invalid_field Turn)
  else if round <= 0 then Error (Invalid_field Round)
  else if String.trim tool_name = "" then Error (Invalid_field Tool_name)
  else if duration_ms < 0 then Error (Invalid_field Duration_ms)
  else if String.trim execution_id = "" then Error (Invalid_field Execution_id)
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
               ; turn
               ; round
               ; tool_name
               ; arguments
               ; outcome
               ; duration_ms
               ; execution_id
               })

type trajectory_outcome =
  | Completed
  | Failed of string
  | Timeout
  | Gated of string  (** rejected by pre-execution gate *)

type trajectory = {
  keeper_name : string;
  trace_id : string;
  generation : int;
  started_at : float;
  ended_at : float;
  entries : tool_call_entry list;
  total_turns : int;
  total_tool_calls : int;
  outcome : trajectory_outcome;
}

(* ================================================================ *)
(* Thinking entries                                                  *)
(* ================================================================ *)

type thinking_entry = {
  ts : float;
  ts_iso : string;
  turn : int;
  block_index : int;
  block : Agent_sdk.Types.content_block;
}

let make_thinking_entry ~ts ~ts_iso ~turn ~block_index ~block =
  if not (Float.is_finite ts) then Error (Invalid_field Timestamp)
  else if String.trim ts_iso = "" then Error (Invalid_field Timestamp_iso)
  else if turn < 0 then Error (Invalid_field Turn)
  else if block_index < 0 then Error (Invalid_field Block_index)
  else
    match block with
    | (Agent_sdk.Types.Thinking _
      | Agent_sdk.Types.ReasoningDetails _
      | Agent_sdk.Types.RedactedThinking _) as block ->
        Ok { ts; ts_iso; turn; block_index; block }
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

type persistence_operation =
  | Append_tool_call
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
  | Append_tool_call -> "append_tool_call"
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

let outcome_to_json = function
  | Completed -> `String "completed"
  | Failed msg -> `Assoc [("status", `String "failed"); ("reason", `String msg)]
  | Timeout -> `String "timeout"
  | Gated reason -> `Assoc [("status", `String "gated"); ("reason", `String reason)]

let outcome_to_string = function
  | Completed -> "completed"
  | Failed msg -> Printf.sprintf "failed: %s" msg
  | Timeout -> "timeout"
  | Gated reason -> Printf.sprintf "gated: %s" reason

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

let entry_to_json (e : tool_call_entry) : Yojson.Safe.t =
  `Assoc
    ([
       ("ts", `Float e.ts);
       ("ts_iso", `String e.ts_iso);
       ("turn", `Int e.turn);
       ("round", `Int e.round);
       ("tool_name", `String e.tool_name);
       ("args", `Assoc e.arguments);
       ("outcome", tool_call_outcome_to_json e.outcome);
       ("duration_ms", `Int e.duration_ms);
       ("execution_id", `String e.execution_id);
     ]
    )

let thinking_entry_to_json (e : thinking_entry) : Yojson.Safe.t =
  `Assoc [
    ("type", `String "thinking");
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("turn", `Int e.turn);
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
    ("keeper_name", `String t.keeper_name);
    ("trace_id", `String t.trace_id);
    ("generation", `Int t.generation);
    ("started_at", `Float t.started_at);
    ("ended_at", `Float t.ended_at);
    ("total_turns", `Int t.total_turns);
    ("total_tool_calls", `Int t.total_tool_calls);
    ("outcome", outcome_to_json t.outcome);
    ("entries", `List (List.map entry_to_json t.entries));
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

let tool_call_fields =
  Set_util.StringSet.of_list
    [ "ts"; "ts_iso"; "turn"; "round"; "tool_name"; "args"; "outcome"
    ; "duration_ms"; "execution_id"
    ]

let thinking_fields =
  Set_util.StringSet.of_list
    [ "type"; "ts"; "ts_iso"; "turn"; "block_index"; "block" ]

let decode_tool_call_entry json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:tool_call_fields json in
  let* ts_json = required_member Timestamp "ts" json in
  let* ts = decode_finite_number Timestamp ts_json in
  let* ts_iso_json = required_member Timestamp_iso "ts_iso" json in
  let* ts_iso = decode_non_blank_string Timestamp_iso ts_iso_json in
  let* turn_json = required_member Turn "turn" json in
  let* turn = decode_nonnegative_int Turn turn_json in
  let* round_json = required_member Round "round" json in
  let* round = decode_positive_int Round round_json in
  let* tool_name_json = required_member Tool_name "tool_name" json in
  let* tool_name = decode_non_blank_string Tool_name tool_name_json in
  let* args_value = required_member Arguments "args" json in
  let* arguments = decode_arguments args_value in
  let* outcome_json = required_member Tool_outcome "outcome" json in
  let* outcome = decode_tool_call_outcome outcome_json in
  let* duration_json = required_member Duration_ms "duration_ms" json in
  let* duration_ms = decode_nonnegative_int Duration_ms duration_json in
  let* execution_id_json = required_member Execution_id "execution_id" json in
  let* execution_id = decode_non_blank_string Execution_id execution_id_json in
  make_tool_call_entry ~ts ~ts_iso ~turn ~round ~tool_name ~arguments ~outcome
    ~duration_ms ~execution_id

let tool_call_entry_of_json (json : Yojson.Safe.t) : tool_call_entry_decode =
  match Json_util.assoc_member_opt "type" json with
  | Some (`String "trajectory_summary") -> Non_entry_row
  | Some (`String "thinking") -> Non_entry_row
  | Some (`String row_type) -> Invalid_entry (Unsupported_row_type row_type)
  | Some _ -> Invalid_entry (Invalid_field Row_type)
  | None ->
      (match decode_tool_call_entry json with
       | Ok entry -> Decoded_entry entry
       | Error error -> Invalid_entry error)

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
  Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper_name)

let trajectory_path (masc_root : string) (keeper_name : string) (trace_id : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name)
    (Printf.sprintf "%s.jsonl" trace_id)

(* All trajectory rows cross [append_jsonl_rows], which delegates to the
   private, durable, per-path locked append boundary in [Fs_compat]. *)

(* ── In-memory round counter ──────────────────────────────────────
   Key: (masc_root, keeper_name, trace_id, turn) -> last issued Tool round.
   Hydrated lazily from the latest canonical Tool row on first access. *)

type round_key = string * string * string * int

let round_counters : (round_key, int) Hashtbl.t = Hashtbl.create 64
let round_counters_mu = Stdlib.Mutex.create ()

type round_hydration_error =
  | Malformed_round_row of { trace_id : string; detail : string }
  | Invalid_round_row of
      { trace_id : string
      ; error : entry_decode_error
      }
  | Round_store_error of { path : string; detail : string }

exception Round_hydration_error of round_hydration_error

let round_hydration_error_to_string = function
  | Malformed_round_row { trace_id; detail } ->
      Printf.sprintf "trace %s contains malformed JSON: %s" trace_id detail
  | Invalid_round_row { trace_id; error } ->
      Printf.sprintf "trace %s contains an invalid row: %s" trace_id
        (entry_decode_error_to_string error)
  | Round_store_error { path; detail } ->
      Printf.sprintf "round hydration failed for %s: %s" path detail

let () =
  Printexc.register_printer (function
    | Round_hydration_error error ->
        Some (round_hydration_error_to_string error)
    | _ -> None)

(** Decode one complete Tool row. Thinking and summary rows do not participate
    in Tool round allocation. Invalid rows fail hydration explicitly so a
    corrupted suffix cannot cause an already-persisted round to be reused. *)
let tool_entry_of_line ~(trace_id : string) (line : string) : tool_call_entry option =
  match Yojson.Safe.from_string line with
  | json ->
      (match tool_call_entry_of_json json with
       | Decoded_entry entry -> Some entry
       | Non_entry_row -> None
       | Invalid_entry error ->
           raise (Round_hydration_error (Invalid_round_row { trace_id; error })))
  | exception Yojson.Json_error msg ->
      raise
        (Round_hydration_error
           (Malformed_round_row { trace_id; detail = msg }))
  | exception exn ->
      raise
        (Round_hydration_error
           (Malformed_round_row
              { trace_id; detail = Printexc.to_string exn }))

type round_tail_search =
  | Round_found of int
  | Older_turn_reached
  | Older_rows_required

let search_round_tail ~(trace_id : string) ~(target_turn : int)
    (window : string list) : round_tail_search =
  let rec search = function
    | [] -> Older_rows_required
    | line :: older ->
        (match tool_entry_of_line ~trace_id line with
         | None -> search older
         | Some entry when entry.turn > target_turn -> search older
         | Some entry when entry.turn = target_turn -> Round_found entry.round
         | Some _ -> Older_turn_reached)
  in
  search (List.rev window)

(** Hydrate from the latest durable Tool round for [turn]. The reader performs
    an exact exponential tail search: it starts with the last physical row and
    widens only while every observed Tool row belongs to a later turn. There is
    no semantic threshold, cap, or count-based fallback. *)
let hydrate_latest_round ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) ~(turn : int) : int =
  let path = trajectory_path masc_root keeper_name trace_id in
  let rec attempt max_lines =
    match Dated_jsonl.load_tail_lines_result path ~max_lines with
    | Error error ->
        raise
          (Round_hydration_error
             (Round_store_error
                { path; detail = Dated_jsonl.read_error_to_string error }))
    | Ok window ->
        (match search_round_tail ~trace_id ~target_turn:turn window with
         | Round_found round -> round
         | Older_turn_reached -> 0
         | Older_rows_required when List.length window < max_lines -> 0
         | Older_rows_required -> attempt (max_lines * 2))
  in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> 0
  | Fs_compat.Exact_kind kind when kind = Unix.S_REG -> attempt 1
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      raise
        (Round_hydration_error
           (Round_store_error
              { path; detail = "trajectory path is not a regular file" }))
  | exception Sys_error detail ->
      raise (Round_hydration_error (Round_store_error { path; detail }))
  | exception (Unix.Unix_error _ as exn) ->
      raise
        (Round_hydration_error
           (Round_store_error { path; detail = Printexc.to_string exn }))

(** Evict active state for older turns under the same base/Keeper/trace. A late
    call rehydrates its latest durable round instead of retaining one
    process-local entry per turn forever. Caller holds [round_counters_mu]. *)
let evict_past_turn_keys ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string)
    ~(turn : int) : unit =
  let stale =
    Hashtbl.fold
      (fun ((root, k, t, kt) as key) _ acc ->
        if String.equal root masc_root && String.equal k keeper_name
           && String.equal t trace_id && kt < turn
        then key :: acc
        else acc)
      round_counters []
  in
  List.iter (Hashtbl.remove round_counters) stale

(** Get the next round number for a given (keeper_name, trace_id, turn).
    Lazily hydrates from disk on first access, then increments in-memory.
    This avoids reading the entire JSONL file on every tool call. *)
let next_round ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string) ~(turn : int) : int =
  let key = (masc_root, keeper_name, trace_id, turn) in
  let issue_locked current =
    let next = current + 1 in
    Hashtbl.replace round_counters key next;
    evict_past_turn_keys ~masc_root ~keeper_name ~trace_id ~turn;
    next
  in
  match
    Stdlib.Mutex.protect round_counters_mu (fun () ->
      Option.map issue_locked (Hashtbl.find_opt round_counters key))
  with
  | Some next -> next
  | None ->
      (* Disk hydration must never run under the process-wide counter lock: one
         cold or large trace must not block unrelated Keeper lanes. A second
         lock phase resolves concurrent cold misses for the same key. *)
      let hydrated =
        hydrate_latest_round ~masc_root ~keeper_name ~trace_id ~turn
      in
      Stdlib.Mutex.protect round_counters_mu (fun () ->
        let current =
          match Hashtbl.find_opt round_counters key with
          | Some current -> current
          | None -> hydrated
        in
        issue_locked current)

(** Reset round counters for testing. *)
let reset_round_counters_for_testing () =
  Stdlib.Mutex.protect round_counters_mu (fun () ->
    Hashtbl.reset round_counters)

let summary_to_json (traj : trajectory) =
  `Assoc [
    ("type", `String "trajectory_summary");
    ("keeper_name", `String traj.keeper_name);
    ("trace_id", `String traj.trace_id);
    ("generation", `Int traj.generation);
    ("total_turns", `Int traj.total_turns);
    ("total_tool_calls", `Int traj.total_tool_calls);
    ("outcome", outcome_to_json traj.outcome);
    ("started_at", `Float traj.started_at);
    ("ended_at", `Float traj.ended_at);
  ]

let append_tool_call_direct ~(masc_root : string)
    ~(keeper_name : string) ~(trace_id : string) (entry : tool_call_entry) :
    unit =
  let path = trajectory_path masc_root keeper_name trace_id in
  let json = entry_to_json entry in
  append_jsonl_rows ~operation:Append_tool_call ~path [ json ]

(* ================================================================ *)
(* Trajectory accumulator (mutable, per-session)                    *)
(* ================================================================ *)

type pending_entry = {
  pe_json : Yojson.Safe.t;
}

type accumulator = {
  mutable entries : tool_call_entry list;
  mutable total_calls : int;
  mutable turn : int;
  keeper_name : string;
  trace_id : string;
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
let active_accumulators : (string * string * string, accumulator) Hashtbl.t =
  Hashtbl.create 16
let active_acc_mu = Stdlib.Mutex.create ()

type accumulator_registration_error =
  | Active_accumulator_exists of
      { masc_root : string
      ; keeper_name : string
      ; trace_id : string
      }

exception Accumulator_registration_error of accumulator_registration_error

let accumulator_registration_error_to_string = function
  | Active_accumulator_exists { masc_root; keeper_name; trace_id } ->
      Printf.sprintf
        "active trajectory accumulator already exists (root=%s keeper=%s trace=%s)"
        masc_root keeper_name trace_id

let () =
  Printexc.register_printer (function
    | Accumulator_registration_error error ->
        Some (accumulator_registration_error_to_string error)
    | _ -> None)

let register_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    let key = acc.masc_root, acc.keeper_name, acc.trace_id in
    if Hashtbl.mem active_accumulators key then
      raise
        (Accumulator_registration_error
           (Active_accumulator_exists
              { masc_root = acc.masc_root
              ; keeper_name = acc.keeper_name
              ; trace_id = acc.trace_id
              }));
    Hashtbl.add active_accumulators key acc)

let unregister_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.remove active_accumulators
      (acc.masc_root, acc.keeper_name, acc.trace_id))

let create_accumulator ?on_flush_error ~masc_root ~keeper_name ~trace_id ~generation () : accumulator =
  let acc = {
    entries = [];
    total_calls = 0;
    turn = 0;
    keeper_name;
    trace_id;
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
let accumulator_turn (acc : accumulator) = acc.turn
let accumulator_entries (acc : accumulator) = acc.entries

let increment_turn (acc : accumulator) : unit =
  acc.turn <- acc.turn + 1

let record_entry (acc : accumulator) (entry : tool_call_entry) : unit =
  let json = entry_to_json entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    if acc.finalized then
      invalid_arg "cannot record a trajectory entry after finalization";
    acc.entries <- entry :: acc.entries;
    acc.total_calls <- acc.total_calls + 1;
    Queue.push { pe_json = json } acc.pending_queue)

let record_thinking (acc : accumulator) (entry : thinking_entry) : unit =
  let json = thinking_entry_to_json entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    if acc.finalized then
      invalid_arg "cannot record a Thinking entry after finalization";
    Queue.push { pe_json = json } acc.pending_queue)

let active_accumulator ~masc_root ~keeper_name ~trace_id =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.find_opt active_accumulators (masc_root, keeper_name, trace_id))

let record_tool_call ~masc_root ~keeper_name ~trace_id
    (entry : tool_call_entry) : unit =
  match active_accumulator ~masc_root ~keeper_name ~trace_id with
  | Some acc -> record_entry acc entry
  | None -> append_tool_call_direct ~masc_root ~keeper_name ~trace_id entry

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
      generation = acc.generation;
      started_at = acc.started_at;
      ended_at = Time_compat.now ();
      entries = List.rev acc.entries;
      total_turns = acc.turn;
      total_tool_calls = acc.total_calls;
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
    Scans the keeper's trajectory directory for all trace files. *)
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
               let decode_file content =
                 String.split_on_char '\n' content
                 |> List.iter (fun line ->
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
                              | Invalid_entry error
                                when row_may_be_in_window json ->
                                  record_invalid_entry decode error
                              | Invalid_entry _ -> ())
               in
               match Fs_compat.exact_path_kind path with
               | exception Sys_error message -> record_io_error message
               | exception (Unix.Unix_error _ as exn) ->
                   record_io_error (Printexc.to_string exn)
               | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
                   (match Fs_compat.load_file path with
                    | content -> decode_file content
                    | exception Sys_error message -> record_io_error message
                    | exception (Unix.Unix_error _ as exn) ->
                        record_io_error (Printexc.to_string exn))
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

let read_entries_result ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) : entries_read_result =
  let path = trajectory_path masc_root keeper_name trace_id in
  let empty_result io_errors =
    { entries = []; decode = empty_entry_decode_summary; io_errors }
  in
  let decode content =
      let decode_summary = create_decode_accumulator () in
      let entries_rev =
        String.split_on_char '\n' content
        |> List.filter (fun line -> String.trim line <> "")
        |> List.fold_left
             (fun entries line ->
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
             []
      in
      {
        entries = List.rev entries_rev;
        decode = decode_accumulator_snapshot decode_summary;
        io_errors = [];
      }
  in
  match Fs_compat.exact_path_kind path with
  | exception Sys_error message -> empty_result [{ path; message }]
  | exception (Unix.Unix_error _ as exn) ->
      empty_result [{ path; message = Printexc.to_string exn }]
  | Fs_compat.Exact_missing -> empty_result []
  | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
      (match Fs_compat.load_file path with
       | content -> decode content
       | exception Sys_error message -> empty_result [{ path; message }]
       | exception (Unix.Unix_error _ as exn) ->
           empty_result [{ path; message = Printexc.to_string exn }])
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      empty_result
        [{ path; message = "trajectory path is not a regular file" }]

type trajectory_line_decode_result =
  | Parsed_line of trajectory_line
  | Skipped_line
  | Invalid_line of entry_decode_error

let decode_thinking_entry json =
  let ( let* ) = Result.bind in
  let* () = validate_object_fields ~allowed:thinking_fields json in
  let* ts_json = required_member Timestamp "ts" json in
  let* ts = decode_finite_number Timestamp ts_json in
  let* ts_iso_json = required_member Timestamp_iso "ts_iso" json in
  let* ts_iso = decode_non_blank_string Timestamp_iso ts_iso_json in
  let* turn_json = required_member Turn "turn" json in
  let* turn = decode_nonnegative_int Turn turn_json in
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
  make_thinking_entry ~ts ~ts_iso ~turn ~block_index ~block

let trajectory_line_of_json json =
  match Json_util.assoc_member_opt "type" json with
  | Some (`String "trajectory_summary") -> Skipped_line
  | Some (`String "thinking") ->
      (match decode_thinking_entry json with
       | Ok entry -> Parsed_line (Thinking entry)
       | Error error -> Invalid_line error)
  | Some (`String row_type) -> Invalid_line (Unsupported_row_type row_type)
  | Some _ -> Invalid_line (Invalid_field Row_type)
  | None ->
      (match tool_call_entry_of_json json with
       | Decoded_entry entry -> Parsed_line (Tool_call entry)
       | Non_entry_row -> Skipped_line
       | Invalid_entry error -> Invalid_line error)
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

let trajectory_lines_of_jsonl_lines lines =
  let decode_summary = create_line_decode_accumulator () in
  let lines_rev =
    List.fold_left
      (fun acc line ->
         if String.trim line = "" then acc
         else
           let decode =
             try Yojson.Safe.from_string line |> trajectory_line_of_json with
             | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ ->
                 Invalid_line Malformed_json
           in
           match decode with
           | Parsed_line (Tool_call _ as parsed) ->
               decode_summary.tool_call_count <-
                 decode_summary.tool_call_count + 1;
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
               acc)
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
    (match Fs_compat.load_file path with
    | exception Sys_error message -> empty_result [{ path; message }]
    | exception (Unix.Unix_error _ as exn) ->
        empty_result [{ path; message = Printexc.to_string exn }]
    | content ->
        String.split_on_char '\n' content
        |> List.filter (fun line -> String.trim line <> "")
        |> trajectory_lines_of_jsonl_lines)
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      empty_result
        [{ path; message = "trajectory path is not a regular file" }]

let read_recent_lines_result
      ~(masc_root : string)
      ~(keeper_name : string)
      ~(trace_id : string)
      ~(max_lines : int)
  : trajectory_lines_read_result
  =
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
    (match Dated_jsonl.load_tail_lines path ~max_lines with
    | exception Sys_error message ->
        empty_result [{ path; message }]
    | exception (Unix.Unix_error _ as exn) ->
        empty_result [{ path; message = Printexc.to_string exn }]
    | lines ->
        if lines <> [] then trajectory_lines_of_jsonl_lines lines
        else
          (match Fs_compat.exact_path_kind path with
           | Fs_compat.Exact_kind kind when kind = Unix.S_REG ->
               trajectory_lines_of_jsonl_lines lines
           | Fs_compat.Exact_missing ->
               empty_result
                 [{ path; message = "trajectory file disappeared during read" }]
           | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
               empty_result
                 [{ path; message = "trajectory path changed during read" }]
           | exception Sys_error message -> empty_result [{ path; message }]
           | exception (Unix.Unix_error _ as exn) ->
               empty_result [{ path; message = Printexc.to_string exn }]))
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      empty_result
        [{ path; message = "trajectory path is not a regular file" }]
