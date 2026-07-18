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

type tool_call_entry = {
  ts : float;                       (** Unix timestamp *)
  ts_iso : string;                  (** ISO8601 string *)
  turn : int;                       (** Turn number within session *)
  round : int;                      (** Monotonic Tool round within turn *)
  tool_name : string;
  arguments : (string * Yojson.Safe.t) list;
      (** Structured Tool arguments. The association-list type enforces the
          JSON object invariant without a second string representation. *)
  result : string option;
  duration_ms : int;                (** Wall-clock execution time *)
  error : string option;            (** Exception message if failed *)
  execution_id : string option;
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
  | Result
  | Duration_ms
  | Error_message
  | Execution_id
  | Content
  | Content_length
  | Redacted

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
  content : string;
  content_length : int;
  redacted : bool;
}

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

(** Default truncation limit for result text in display projections. *)
let default_result_truncation = 500

let entry_to_json ?(result_max_len = default_result_truncation)
    (e : tool_call_entry) : Yojson.Safe.t =
  `Assoc
    ([
       ("ts", `Float e.ts);
       ("ts_iso", `String e.ts_iso);
       ("turn", `Int e.turn);
       ("round", `Int e.round);
       ("tool_name", `String e.tool_name);
       ("args", `Assoc e.arguments);
       ( "result",
         (match e.result with
          | None -> `Null
          | Some r ->
              if result_max_len > 0 then
                `String
                  (String_util.utf8_safe
                     ~max_bytes:(result_max_len + 3)
                     ~suffix:"..."
                     r
                   |> String_util.to_string)
              else `String r) );
       ("duration_ms", `Int e.duration_ms);
       ("error", Json_util.string_opt_to_json e.error);
     ]
     @ (match e.execution_id with
        | Some id -> [ ("execution_id", `String id) ]
        | None -> []))

let default_thinking_truncation = 2000

let thinking_entry_to_json ?(content_max_len = default_thinking_truncation) (e : thinking_entry) : Yojson.Safe.t =
  let content =
    if content_max_len > 0 then
      String_util.utf8_safe ~max_bytes:(content_max_len + 3) ~suffix:"..."
        e.content
      |> String_util.to_string
    else e.content
  in
  `Assoc [
    ("type", `String "thinking");
    ("ts", `Float e.ts);
    ("ts_iso", `String e.ts_iso);
    ("turn", `Int e.turn);
    ("content", `String content);
    ("content_length", `Int e.content_length);
    ("redacted", `Bool e.redacted);
  ]

let trajectory_line_to_json ?(result_max_len = default_result_truncation)
    ?(content_max_len = default_thinking_truncation) = function
  | Tool_call e -> entry_to_json ~result_max_len e
  | Thinking e -> thinking_entry_to_json ~content_max_len e

(* Durable trajectory rows are the trace authority.  Keep their serializer
   separate from display projections so a caller cannot accidentally make a
   presentation limit destructive. *)
let persisted_entry_to_json = entry_to_json ~result_max_len:0

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
    ("entries", `List (List.map persisted_entry_to_json t.entries));
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

let decode_nullable_string field = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error (Invalid_field field)

let decode_bool field = function
  | `Bool value -> Ok value
  | _ -> Error (Invalid_field field)

let decode_arguments = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Invalid_field Arguments)

let decode_optional_execution_id json =
  match Json_util.assoc_member_opt "execution_id" json with
  | None | Some `Null -> Ok None
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some _ -> Error (Invalid_field Execution_id)

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
    [ "ts"; "ts_iso"; "turn"; "round"; "tool_name"; "args"; "result"
    ; "duration_ms"; "error"; "execution_id"
    ]

let thinking_fields =
  Set_util.StringSet.of_list
    [ "type"; "ts"; "ts_iso"; "turn"; "content"; "content_length"
    ; "redacted"
    ]

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
  let* round = decode_nonnegative_int Round round_json in
  let* tool_name_json = required_member Tool_name "tool_name" json in
  let* tool_name = decode_non_blank_string Tool_name tool_name_json in
  let* args_value = required_member Arguments "args" json in
  let* arguments = decode_arguments args_value in
  let* result_json = required_member Result "result" json in
  let* result = decode_nullable_string Result result_json in
  let* duration_json = required_member Duration_ms "duration_ms" json in
  let* duration_ms = decode_nonnegative_int Duration_ms duration_json in
  let* error_json = required_member Error_message "error" json in
  let* error = decode_nullable_string Error_message error_json in
  let* execution_id = decode_optional_execution_id json in
  Ok
    {
      ts;
      ts_iso;
      turn;
      round;
      tool_name;
      arguments;
      result;
      duration_ms;
      error;
      execution_id;
    }

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
  Option.is_some e.error

(* ================================================================ *)
(* File I/O                                                         *)
(* ================================================================ *)

let trajectories_dir (masc_root : string) (keeper_name : string) : string =
  Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper_name)

let trajectory_path (masc_root : string) (keeper_name : string) (trace_id : string) : string =
  Filename.concat (trajectories_dir masc_root keeper_name)
    (Printf.sprintf "%s.jsonl" trace_id)

(* RFC-0108: the inline per-path Stdlib.Mutex + fresh-fd helper
   (PR-4 #15926) is removed here. [Fs_compat.append_jsonl] (post-RFC-0108
   #15936) now provides the equivalent per-path cross-domain guarantee
   via its own registry, so the trajectory-local copy is redundant.
   Calls below delegate directly. *)

(* ── In-memory round counter ──────────────────────────────────────
   Replaces the read-all-entries-just-to-count-round pattern.
   Key: (keeper_name, trace_id, turn) -> count of tool calls in that turn.
   Hydrated lazily on first access per key. *)

let round_counters : (string * string * int, int) Hashtbl.t = Hashtbl.create 64
let round_high_water : (string * string * int, int) Hashtbl.t = Hashtbl.create 64
let round_counters_mu = Stdlib.Mutex.create ()

(* Initial tail window (in lines) read to hydrate a turn's round count from
   disk. A single turn's tool-call count is far below this bound, so one
   tail read normally captures the whole turn plus the previous-turn boundary.
   Chosen well above realistic per-turn tool-call counts to avoid widening. *)
let default_hydrate_tail_lines = 512

(* Upper bound on the tail window before falling back to a full-file scan.
   Doubling from [default_hydrate_tail_lines] yields 512→1024→2048→4096→8192.
   Beyond this a turn is assumed pathological and a full scan is used so the
   count is never silently truncated. *)
let max_hydrate_tail_lines = 8192

(** Extract the [turn] field from a trajectory JSONL line.  Returns [None] for
    non-entry rows, malformed [turn] fields, and invalid JSON.  Such lines are
    skipped rather than counted or treated as turn-boundaries. *)
let entry_turn_of_line ~(trace_id : string) (line : string) : int option =
  match Yojson.Safe.from_string line with
  | json -> (
      match Json_util.assoc_member_opt "turn" json with
      | Some (`Int n) -> Some n
      | None -> None
      | Some other ->
          Log.Keeper.warn
            "Skipping trajectory line with non-int turn during next_round \
             (trace_id=%s, turn_kind=%s)"
            trace_id (Yojson.Safe.to_string other);
          None)
  | exception Yojson.Json_error msg ->
      Log.Keeper.warn
        "Failed to parse trajectory JSON during next_round (trace_id=%s): %s"
        trace_id msg;
      None
  | exception exn ->
      Log.Keeper.warn
        "Unexpected error reading trajectory line (trace_id=%s): %s" trace_id
        (Printexc.to_string exn);
      None

(** Count entries whose [turn = target_turn] within a tail [window] by scanning
    newest→oldest, stopping at the first line strictly older than [target_turn].
    turn is monotonically non-decreasing in append-only file order, so once a
    line with [entry_turn < target_turn] is seen every earlier line is a past
    turn and the scan stops.

    Returns [(count, boundary_found)]. [boundary_found] is true only when a
    strictly-older line was seen, i.e. the window definitely contained the turn
    boundary and [count] is complete. When false, the window may have been
    truncated before the boundary and the caller must widen it or fall back. *)
let count_current_turn_backward ~(trace_id : string) ~(target_turn : int)
    (window : string list) : int * bool =
  (* [window] is oldest-first (load_tail_lines order); reverse to scan the
     newest line first so we can stop as soon as the boundary appears. *)
  let rec scan count = function
    | [] -> (count, false)
    | line :: older -> (
        match entry_turn_of_line ~trace_id line with
        | None -> scan count older (* unparseable: warn+skip, not a boundary *)
        | Some entry_turn ->
            if entry_turn = target_turn then scan (count + 1) older
            else if entry_turn < target_turn then (count, true) (* boundary *)
            else (
              (* entry_turn > target_turn cannot occur under monotonic turn:
                 future turns are appended after, not before, the current turn.
                 Exclude it from the count but keep scanning (do not treat it as
                 a boundary) so an upstream anomaly cannot silently truncate. *)
              Log.Keeper.warn
                "next_round saw future turn %d > %d in trajectory tail \
                 (trace_id=%s); excluding from round count"
                entry_turn target_turn trace_id;
              scan count older))
  in
  scan 0 (List.rev window)

(** Full-file scan fallback: count entries whose [turn = target_turn] across the
    whole trajectory file. Restores the pre-tail-read O(file) cost, used only
    when a turn exceeds [max_hydrate_tail_lines] tool calls. *)
let full_scan_round_count ~(path : string) ~(trace_id : string)
    ~(target_turn : int) : int =
  Fs_compat.load_file path
  |> String.split_on_char '\n'
  |> List.filter (fun line -> String.trim line <> "")
  |> List.fold_left
       (fun acc line ->
         match entry_turn_of_line ~trace_id line with
         | Some n when n = target_turn -> acc + 1
         | _ -> acc)
       0

(** Count existing entries for [turn] by reading a bounded tail of the file
    instead of the whole file. Widens the window (doubling) if the boundary is
    not reached, and only falls back to a full scan past [max_hydrate_tail_lines]
    so the count is exact for every turn size. *)
let hydrate_round_count ~(masc_root : string) ~(keeper_name : string)
    ~(trace_id : string) ~(turn : int) : int =
  let path = trajectory_path masc_root keeper_name trace_id in
  if not (Sys.file_exists path) then 0
  else
    let rec attempt max_lines =
      let window = Dated_jsonl.load_tail_lines path ~max_lines in
      let n = List.length window in
      let count, boundary_found =
        count_current_turn_backward ~trace_id ~target_turn:turn window
      in
      if boundary_found || n < max_lines then
        (* boundary_found: the previous-turn marker was inside the window.
           n < max_lines: load_tail_lines returned fewer lines than requested,
           so the window already spans the whole file — trajectory JSONL is
           append-only with one record per line and no interior blank lines —
           and [count] is complete even without an explicit boundary (e.g. the
           first turn, whose entries reach the top of the file). *)
        count
      else if max_lines >= max_hydrate_tail_lines then (
        (* Window filled to the cap without reaching the boundary. Fall back to
           a full scan rather than risk under-counting a pathologically large
           turn. This restores the pre-optimization cost for that rare case
           only, and never silently truncates. *)
        Log.Keeper.warn
          "next_round tail window exhausted at %d lines without turn boundary \
           (trace_id=%s, turn=%d); falling back to full scan"
          max_lines trace_id turn;
        full_scan_round_count ~path ~trace_id ~target_turn:turn)
      else attempt (max_lines * 2)
    in
    attempt default_hydrate_tail_lines

(** Evict cache entries for turns older than [turn] under the same
    (keeper_name, trace_id). Round counts for a past turn are never queried
    again in the normal monotonic path, so retaining the active hydrated
    counter would grow the table without bound over a long session. Issued
    high-water marks are intentionally retained separately; if a late
    out-of-order caller asks for an older turn, [next_round] must not hand out
    a duplicate round number already returned by this process. Caller must
    hold [round_counters_mu]. *)
let evict_past_turn_keys ~(keeper_name : string) ~(trace_id : string)
    ~(turn : int) : unit =
  let stale =
    Hashtbl.fold
      (fun ((k, t, kt) as key) _ acc ->
        if String.equal k keeper_name && String.equal t trace_id && kt < turn
        then key :: acc
        else acc)
      round_counters []
  in
  List.iter (Hashtbl.remove round_counters) stale

(** Get the next round number for a given (keeper_name, trace_id, turn).
    Lazily hydrates from disk on first access, then increments in-memory.
    This avoids reading the entire JSONL file on every tool call. *)
let next_round ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string) ~(turn : int) : int =
  let key = (keeper_name, trace_id, turn) in
  let issue_locked current =
    let next = current + 1 in
    Hashtbl.replace round_counters key next;
    Hashtbl.replace round_high_water key next;
    evict_past_turn_keys ~keeper_name ~trace_id ~turn;
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
        hydrate_round_count ~masc_root ~keeper_name ~trace_id ~turn
      in
      Stdlib.Mutex.protect round_counters_mu (fun () ->
        let current =
          match Hashtbl.find_opt round_counters key with
          | Some current -> current
          | None ->
              let issued =
                Option.value (Hashtbl.find_opt round_high_water key) ~default:0
              in
              max hydrated issued
        in
        issue_locked current)

(** Reset round counters for testing. *)
let reset_round_counters_for_testing () =
  Stdlib.Mutex.protect round_counters_mu (fun () ->
    Hashtbl.reset round_counters;
    Hashtbl.reset round_high_water)

(** Append a thinking block entry to the JSONL trajectory file. *)
let append_thinking ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (entry : thinking_entry) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  (* 남김없이: the thinking trajectory is the eval/audit SSOT, so persist the
     FULL untruncated reasoning text. Truncation is a read/display concern
     ([content_max_len] query param on the trajectory endpoint), never a
     write-time one — truncating here destroyed reasoning before it was ever
     stored. [content_length] still records the true length either way. *)
  let json = thinking_entry_to_json ~content_max_len:0 entry in
  Fs_compat.append_jsonl path json

(** Write a trajectory summary line (appended after session ends). *)
let append_summary ~(masc_root : string) ~(keeper_name : string) ~(trace_id : string)
    (traj : trajectory) : unit =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let summary = `Assoc [
    ("type", `String "trajectory_summary");
    ("keeper_name", `String traj.keeper_name);
    ("trace_id", `String traj.trace_id);
    ("generation", `Int traj.generation);
    ("total_turns", `Int traj.total_turns);
    ("total_tool_calls", `Int traj.total_tool_calls);
    ("outcome", outcome_to_json traj.outcome);
    ("started_at", `Float traj.started_at);
    ("ended_at", `Float traj.ended_at);
  ] in
  Fs_compat.append_jsonl path summary

let append_entry ~(masc_root : string)
    ~(keeper_name : string) ~(trace_id : string) (entry : tool_call_entry) :
    unit =
  let dir = trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = trajectory_path masc_root keeper_name trace_id in
  let json = persisted_entry_to_json entry in
  Fs_compat.append_jsonl path json

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
  mutable last_flush : float;
  mutable on_flush_error : (exn -> unit) option;
}

(* Global registry of active accumulators for batch flush.
   The background flush fiber iterates this to drain pending queues. *)
let active_accumulators : (string * string, accumulator) Hashtbl.t = Hashtbl.create 16
let active_acc_mu = Stdlib.Mutex.create ()

let register_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.replace active_accumulators (acc.keeper_name, acc.trace_id) acc)

let unregister_accumulator (acc : accumulator) =
  Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.remove active_accumulators (acc.keeper_name, acc.trace_id))

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
    last_flush = 0.0;
    on_flush_error;
  } in
  register_accumulator acc;
  acc

let increment_turn (acc : accumulator) : unit =
  acc.turn <- acc.turn + 1

let record_entry ?on_persist_error
    (acc : accumulator) (entry : tool_call_entry) : unit =
  acc.entries <- entry :: acc.entries;
  acc.total_calls <- acc.total_calls + 1;
  (* Store on_persist_error for use during batch flush *)
  (match on_persist_error, acc.on_flush_error with
   | Some cb, None -> acc.on_flush_error <- Some cb
   | _ -> ());
  (* Enqueue for batched write instead of synchronous disk I/O *)
  let json = persisted_entry_to_json entry in
  Stdlib.Mutex.protect acc.pending_mu (fun () ->
    Queue.push { pe_json = json } acc.pending_queue)

(** Drain the pending queue and write all entries in a single batch.
    Acquires the per-accumulator mutex to safely drain the queue. *)
let flush_pending (acc : accumulator) : unit =
  let entries_to_flush =
    Stdlib.Mutex.protect acc.pending_mu (fun () ->
      if Queue.is_empty acc.pending_queue then []
      else
        let items = Queue.fold (fun acc pe -> pe :: acc) [] acc.pending_queue in
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
       let jsons = List.map (fun pe -> pe.pe_json) entries_to_flush in
       Fs_compat.append_jsonl_batch path jsons;
       acc.last_flush <- Time_compat.now ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
       Log.Keeper.error "Failed to flush trajectory batch for %s: %s"
         acc.trace_id (Printexc.to_string exn);
       (match acc.on_flush_error with
        | None -> ()
        | Some report ->
            try report exn
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | report_exn ->
                Log.Keeper.warn
                  "Failed to report trajectory flush error for %s: %s"
                  acc.trace_id
                  (Printexc.to_string report_exn)))

(** Flush pending entries for all active accumulators.
    Called by the background flush fiber in server_runtime_bootstrap. *)
let flush_all_pending () : unit =
  let accs = Stdlib.Mutex.protect active_acc_mu (fun () ->
    Hashtbl.fold (fun _ acc accs -> acc :: accs) active_accumulators []) in
  List.iter flush_pending accs

let finalize (acc : accumulator) (outcome : trajectory_outcome) : trajectory =
  (* Flush any remaining pending entries before writing summary *)
  flush_pending acc;
  unregister_accumulator acc;
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
  (try append_summary ~masc_root:acc.masc_root ~keeper_name:acc.keeper_name
       ~trace_id:acc.trace_id traj
   with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Keeper.error "Failed to persist summary for %s: %s" acc.trace_id (Printexc.to_string exn));
  traj

(** Count tool calls in current turn. *)
let calls_in_current_turn (acc : accumulator) : int =
  List_util.count_if (fun (e : tool_call_entry) -> e.turn = acc.turn) acc.entries

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
    let is_err = Option.is_some e.error in
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
  let* content_json = required_member Content "content" json in
  let* content = decode_string Content content_json in
  let* content_length_json = required_member Content_length "content_length" json in
  let* content_length = decode_nonnegative_int Content_length content_length_json in
  let* redacted_json = required_member Redacted "redacted" json in
  let* redacted = decode_bool Redacted redacted_json in
  Ok { ts; ts_iso; turn; content; content_length; redacted }

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
