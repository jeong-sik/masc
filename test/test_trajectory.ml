(** Unit tests for Trajectory module — JSONL trajectory logging. *)

open Masc

let () =
  (* Ensure RNG is initialized for any code that may need it *)
  ignore (Unix.gettimeofday ())

(* ================================================================ *)
(* Test: gate_decision types                                         *)
(* ================================================================ *)

let rejection_reason value =
  match Trajectory.rejection_reason_of_string value with
  | Some reason -> reason
  | None -> Alcotest.fail "expected non-blank rejection reason"

let test_gate_decision_pass () =
  match Trajectory.Pass with
  | Trajectory.Pass -> ()
  | Trajectory.Reject _ -> Alcotest.fail "Expected Pass"

let test_gate_decision_reject () =
  match Trajectory.Reject (rejection_reason "test reason") with
  | Trajectory.Reject reason ->
      Alcotest.(check string) "reject reason" "test reason"
        (Trajectory.rejection_reason_to_string reason)
  | Trajectory.Pass -> Alcotest.fail "Expected Reject"

(* ================================================================ *)
(* Test: create_accumulator and basic state                          *)
(* ================================================================ *)

let with_tmpdir f =
  let dir = Filename.concat (Filename.get_temp_dir_name ())
    (Printf.sprintf "test_trajectory_%d" (Random.int 100000)) in
  (try Unix.mkdir dir 0o755 with _ -> ());
  Fun.protect ~finally:(fun () ->
    (* Best effort cleanup *)
    Fs_compat.remove_tree dir
  ) (fun () -> f dir)

let test_create_accumulator () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-001" ~generation:0 () in
    Alcotest.(check int) "initial turn" 0 acc.Trajectory.turn;
    Alcotest.(check int) "initial entries" 0 (List.length acc.Trajectory.entries))

(* ================================================================ *)
(* Test: record_entry updates accumulator                            *)
(* ================================================================ *)

let test_record_entry () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-002" ~generation:0 () in
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0;
      ts_iso = "2026-01-01T00:00:00Z";
      turn = 1;
      round = 0;
      tool_name = "tool_execute";
      arguments = [("command", `String "pwd")];
      gate_decision = Trajectory.Pass;
      result = Some "/home/test";
      duration_ms = 50;
      error = None;
      execution_id = Some "exec-1000-0001";
    } in
    Trajectory.record_entry acc entry;
    Alcotest.(check int) "entries count" 1 (List.length acc.Trajectory.entries))

(* ================================================================ *)
(* Test: increment_turn                                              *)
(* ================================================================ *)

let test_increment_turn () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-005" ~generation:0 () in
    Alcotest.(check int) "turn 0" 0 acc.Trajectory.turn;
    Trajectory.increment_turn acc;
    Alcotest.(check int) "turn 1" 1 acc.Trajectory.turn;
    Trajectory.increment_turn acc;
    Alcotest.(check int) "turn 2" 2 acc.Trajectory.turn)

(* ================================================================ *)
(* Test: finalize creates trajectory record                          *)
(* ================================================================ *)

let test_finalize () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-006" ~generation:0 () in
    Trajectory.increment_turn acc;
    let entry : Trajectory.tool_call_entry = {
      ts = 1000.0; ts_iso = "2026-01-01T00:00:00Z";
      turn = 1; round = 0;
      tool_name = "tool_execute"; arguments = [];
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 100;
      error = None;
      execution_id = None;
    } in
    Trajectory.record_entry acc entry;
    let traj = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check int) "total turns" 1 traj.Trajectory.total_turns;
    Alcotest.(check int) "total calls" 1 traj.Trajectory.total_tool_calls;
    Alcotest.(check string) "trace_id" "trace-006" traj.Trajectory.trace_id)

(* ================================================================ *)
(* Test: outcome_to_string                                           *)
(* ================================================================ *)

let test_outcome_to_string () =
  Alcotest.(check string) "completed" "completed"
    (Trajectory.outcome_to_string Trajectory.Completed);
  Alcotest.(check string) "failed" "failed: oops"
    (Trajectory.outcome_to_string (Trajectory.Failed "oops"));
  Alcotest.(check string) "gated" "gated: blocked"
    (Trajectory.outcome_to_string (Trajectory.Gated "blocked"))

(* ================================================================ *)
(* Test: calls_in_current_turn                                       *)
(* ================================================================ *)

let test_calls_in_current_turn () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-007" ~generation:0 () in
    Trajectory.increment_turn acc;
    let mk tool = { Trajectory.
      ts = 1000.0; ts_iso = ""; turn = acc.Trajectory.turn; round = 0;
      tool_name = tool; arguments = [];
      gate_decision = Trajectory.Pass;
      result = Some "ok"; duration_ms = 10;
      error = None;
      execution_id = None;
    } in
    Trajectory.record_entry acc (mk "tool_execute");
    Trajectory.record_entry acc (mk "tool_read_file");
    let count = Trajectory.calls_in_current_turn acc in
    Alcotest.(check int) "calls in turn 1" 2 count)

(* ================================================================ *)
(* Test: aggregate_tool_stats                                        *)
(* ================================================================ *)

let mk_entry ?(ts = 1000.0) ?(error = None) ?(gate = Trajectory.Pass) name dur ts_iso =
  { Trajectory.
    ts; ts_iso; turn = 1; round = 0;
    tool_name = name; arguments = [];
    gate_decision = gate;
    result = Some "ok"; duration_ms = dur;
    error;
    execution_id = None;
  }

let test_aggregate_basic () =
  let entries = [
    mk_entry "tool_execute" 100 "2026-04-06T10:00:00Z";
    mk_entry "tool_execute" 200 "2026-04-06T10:01:00Z";
    mk_entry "tool_execute" 300 "2026-04-06T10:02:00Z";
    mk_entry "tool_read_file" 50 "2026-04-06T10:03:00Z";
  ] in
  let stats = Trajectory.aggregate_tool_stats entries in
  Alcotest.(check int) "tool count" 2 (List.length stats);
  (* tool_execute has more calls, should be first *)
  let bash = List.hd stats in
  Alcotest.(check string) "first tool" "tool_execute" bash.Trajectory.name;
  Alcotest.(check int) "bash call count" 3 bash.Trajectory.call_count;
  Alcotest.(check int) "bash success count" 3 bash.Trajectory.success_count;
  Alcotest.(check int) "bash failure count" 0 bash.Trajectory.failure_count;
  Alcotest.(check int) "bash avg duration" 200 bash.Trajectory.avg_duration_ms;
  Alcotest.(check int) "bash max duration" 300 bash.Trajectory.max_duration_ms

let test_aggregate_with_errors () =
  let entries = [
    mk_entry "tool_execute" 100 "2026-04-06T10:00:00Z";
    mk_entry ~error:(Some "timeout") "tool_execute" 5000 "2026-04-06T10:01:00Z";
    mk_entry ~gate:(Trajectory.Reject (rejection_reason "denied"))
      "tool_execute" 0 "2026-04-06T10:02:00Z";
  ] in
  let stats = Trajectory.aggregate_tool_stats entries in
  Alcotest.(check int) "tool count" 1 (List.length stats);
  let s = List.hd stats in
  Alcotest.(check int) "call count" 3 s.Trajectory.call_count;
  Alcotest.(check int) "success" 1 s.Trajectory.success_count;
  Alcotest.(check int) "failure" 2 s.Trajectory.failure_count

let test_aggregate_empty () =
  let stats = Trajectory.aggregate_tool_stats [] in
  Alcotest.(check int) "empty" 0 (List.length stats)

let test_aggregate_p95 () =
  (* 20 entries: durations 100, 200, ..., 2000. p95 index = round(20 * 0.95) = 19 -> 2000 *)
  let entries = List.init 20 (fun i ->
    mk_entry "tool_execute" ((i + 1) * 100)
      (Printf.sprintf "2026-04-06T10:%02d:00Z" i)
  ) in
  let stats = Trajectory.aggregate_tool_stats entries in
  let s = List.hd stats in
  (* p95 of [100..2000] with 20 items — idx 19 = 2000 *)
  Alcotest.(check int) "p95" 2000 s.Trajectory.p95_duration_ms

(* ================================================================ *)
(* Test: hourly_timeline                                             *)
(* ================================================================ *)

let test_hourly_single_bucket () =
  let entries = [
    { (mk_entry "tool_execute" 100 "2026-04-06T10:05:00Z") with Trajectory.ts = 1743937500.0 };
    { (mk_entry "tool_execute" 100 "2026-04-06T10:30:00Z") with Trajectory.ts = 1743939000.0 };
  ] in
  let timeline = Trajectory.hourly_timeline entries in
  (* Both entries fall in the same hour bucket (25 min apart) *)
  Alcotest.(check int) "bucket count" 1 (List.length timeline);
  let b = List.hd timeline in
  Alcotest.(check int) "call count" 2 b.Trajectory.call_count;
  Alcotest.(check int) "error count" 0 b.Trajectory.error_count

let test_hourly_with_errors () =
  let entries = [
    { (mk_entry "tool_execute" 100 "2026-04-06T10:05:00Z") with Trajectory.ts = 1743937500.0 };
    { (mk_entry ~error:(Some "fail") "tool_execute" 100 "2026-04-06T10:30:00Z") with Trajectory.ts = 1743939000.0 };
  ] in
  let timeline = Trajectory.hourly_timeline entries in
  let b = List.hd timeline in
  Alcotest.(check int) "error count" 1 b.Trajectory.error_count

let test_hourly_empty () =
  let timeline = Trajectory.hourly_timeline [] in
  Alcotest.(check int) "empty" 0 (List.length timeline)

(* ================================================================ *)
(* Test: tool_stat_to_json / hourly_bucket_to_json                   *)
(* ================================================================ *)

let test_tool_stat_json_roundtrip () =
  let stat : Trajectory.tool_stat = {
    name = "tool_execute";
    call_count = 10;
    success_count = 9;
    failure_count = 1;
    avg_duration_ms = 150;
    p95_duration_ms = 500;
    max_duration_ms = 800;
    last_used_at = "2026-04-06T12:00:00Z";
  } in
  let json = Trajectory.tool_stat_to_json stat in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "name" "tool_execute" (json |> member "name" |> to_string);
  Alcotest.(check int) "call_count" 10 (json |> member "call_count" |> to_int);
  Alcotest.(check int) "p95" 500 (json |> member "p95_duration_ms" |> to_int);
  Alcotest.(check int) "failure" 1 (json |> member "failure_count" |> to_int)

let test_hourly_bucket_json () =
  let b : Trajectory.hourly_bucket = {
    hour = "2026-04-06T10:00:00Z";
    call_count = 5;
    error_count = 1;
  } in
  let json = Trajectory.hourly_bucket_to_json b in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "hour" "2026-04-06T10:00:00Z" (json |> member "hour" |> to_string);
  Alcotest.(check int) "calls" 5 (json |> member "call_count" |> to_int);
  Alcotest.(check int) "errors" 1 (json |> member "error_count" |> to_int)

let test_entry_to_json_preserves_typed_fields () =
  let entry : Trajectory.tool_call_entry = {
    ts = 1000.0;
    ts_iso = "2026-04-06T10:00:00Z";
    turn = 1;
    round = 1;
    tool_name = "tool_execute";
    arguments = [("command", `String "pwd")];
    gate_decision = Trajectory.Pass;
    result = Some "/tmp/work";
    duration_ms = 25;
    error = None;
    execution_id = Some "exec-1000-0001";
  } in
  let json = Trajectory.entry_to_json entry in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "structured argument" "pwd"
    (json |> member "args" |> member "command" |> to_string);
  Alcotest.(check string) "execution_id persisted" "exec-1000-0001"
    (json |> member "execution_id" |> to_string)

(* RFC-0233 PR-1: the canonical join key survives the JSONL round-trip and its
   explicitly optional form remains [None]. *)
let test_execution_id_roundtrip () =
  let entry : Trajectory.tool_call_entry = {
    ts = 1000.0; ts_iso = "2026-06-12T00:00:00Z"; turn = 3; round = 1;
    tool_name = "tool_execute"; arguments = [];
    gate_decision = Trajectory.Pass;
    result = Some "ok"; duration_ms = 10; error = None;
    execution_id = Some "exec-1718150400000-0001";
  } in
  (match Trajectory.tool_call_entry_of_json (Trajectory.entry_to_json entry) with
   | Trajectory.Decoded_entry decoded ->
       Alcotest.(check (option string)) "round-trip"
         (Some "exec-1718150400000-0001") decoded.Trajectory.execution_id
   | Trajectory.Non_entry_row | Trajectory.Invalid_entry _ ->
       Alcotest.fail "entry did not decode");
  let without_execution_id =
    Trajectory.entry_to_json { entry with execution_id = None }
  in
  match Trajectory.tool_call_entry_of_json without_execution_id with
  | Trajectory.Decoded_entry decoded ->
      Alcotest.(check (option string)) "optional id remains None" None
        decoded.Trajectory.execution_id
  | Trajectory.Non_entry_row | Trajectory.Invalid_entry _ ->
      Alcotest.fail "entry without execution_id did not decode"

let test_gate_codec_rejects_noncanonical_rows () =
  let base_fields =
    [ ("ts", `Float 1000.0)
    ; ("ts_iso", `String "2026-06-12T00:00:00Z")
    ; ("turn", `Int 1)
    ; ("round", `Int 1)
    ; ("tool_name", `String "tool_execute")
    ; ("args", `Assoc [])
    ; ("result", `String "ok")
    ; ("duration_ms", `Int 1)
    ; ("error", `Null)
    ]
  in
  let base = `Assoc base_fields in
  (match Trajectory.tool_call_entry_of_json base with
   | Trajectory.Invalid_entry (Trajectory.Invalid_gate Trajectory.Missing_gate) -> ()
   | _ -> Alcotest.fail "missing gate must reject the row");
  let with_gate gate = `Assoc (("gate", gate) :: base_fields) in
  (match
     Trajectory.tool_call_entry_of_json
       (with_gate (`Assoc [("status", `String "passed")]))
   with
   | Trajectory.Invalid_entry
       (Trajectory.Invalid_gate
          (Trajectory.Unsupported_gate_status "passed")) -> ()
   | _ -> Alcotest.fail "gate aliases must not decode");
  (match
     Trajectory.tool_call_entry_of_json
       (with_gate (`Assoc [("status", `String "reject")]))
   with
   | Trajectory.Invalid_entry
       (Trajectory.Invalid_gate Trajectory.Missing_reject_reason) -> ()
   | _ -> Alcotest.fail "reject requires an explicit reason");
  match
    Trajectory.tool_call_entry_of_json
      (with_gate
         (`Assoc
            [("status", `String "reject"); ("reason", `String " \t ")]))
  with
  | Trajectory.Invalid_entry
      (Trajectory.Invalid_gate Trajectory.Missing_reject_reason) -> ()
  | _ -> Alcotest.fail "reject requires a non-blank reason"

let test_closed_row_codec_rejects_invalid_fields_and_types () =
  let valid_entry =
    Trajectory.entry_to_json
      (mk_entry "tool_execute" 1 "2026-06-12T00:00:00Z")
  in
  let replace key value = function
    | `Assoc fields ->
        `Assoc ((key, value) :: List.remove_assoc key fields)
    | _ -> Alcotest.fail "entry serializer must return an object"
  in
  let check_invalid_field field json =
    match Trajectory.tool_call_entry_of_json json with
    | Trajectory.Invalid_entry (Trajectory.Invalid_field actual)
      when actual = field -> ()
    | _ -> Alcotest.fail "invalid required field must not be fabricated"
  in
  check_invalid_field Trajectory.Timestamp
    (replace "ts" (`Float Float.nan) valid_entry);
  check_invalid_field Trajectory.Turn (replace "turn" (`Int (-1)) valid_entry);
  check_invalid_field Trajectory.Tool_name
    (replace "tool_name" (`String "") valid_entry);
  check_invalid_field Trajectory.Duration_ms
    (replace "duration_ms" (`Int (-1)) valid_entry);
  check_invalid_field Trajectory.Arguments
    (replace "args" (`String "{}") valid_entry);
  (match
     Trajectory.tool_call_entry_of_json
       (replace "type" (`String "unsupported") valid_entry)
   with
   | Trajectory.Invalid_entry
       (Trajectory.Unsupported_row_type "unsupported") -> ()
   | _ -> Alcotest.fail "unknown row type must not decode as a tool row");
  let invalid_thinking =
    {|{"type":"thinking","ts":1000.0,"ts_iso":"2026-06-12T00:00:00Z","turn":1,"content":"thought","content_length":7,"redacted":"false"}|}
  in
  let decoded =
    Trajectory.trajectory_lines_of_jsonl_lines [ invalid_thinking ]
  in
  Alcotest.(check int) "invalid thinking excluded" 0
    (List.length decoded.Trajectory.lines);
  Alcotest.(check int) "invalid thinking observed" 1
    decoded.Trajectory.line_decode.invalid_line_count;
  Alcotest.(check int) "invalid thinking field reason" 1
    decoded.Trajectory.line_decode.invalid_reasons.invalid_field

(* ================================================================ *)
(* Test: read_entries_since (file-based)                             *)
(* ================================================================ *)

let test_read_entries_since () =
  with_tmpdir (fun dir ->
    let masc_root = dir in
    let keeper = "test-keeper" in
    (* Create a trajectory file manually *)
    let traj_dir = Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper) in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-100.jsonl" in
    let entry_json ts = Printf.sprintf
      {|{"ts":%.1f,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":0,"tool_name":"tool_execute","args":{},"gate":{"status":"pass"},"result":"ok","duration_ms":100,"error":null}|}
      ts
    in
    let oc = open_out path in
    Printf.fprintf oc "%s\n" (entry_json 1000.0);
    Printf.fprintf oc "%s\n" (entry_json 2000.0);
    Printf.fprintf oc "%s\n" (entry_json 3000.0);
    close_out oc;
    (* Read since ts=1500 should get 2 entries *)
    let entries =
      Trajectory.read_entries_since_result ~masc_root ~keeper_name:keeper
        ~since:1500.0
    in
    Alcotest.(check int) "entries since 1500" 2
      (List.length entries.Trajectory.entries);
    Alcotest.(check int) "all filtered rows pass" 2
      entries.Trajectory.gate_decode.passed_gate_count;
    Alcotest.(check int) "no read errors" 0
      (List.length entries.Trajectory.io_errors);
    (* Read since ts=0 should get all 3 *)
    let all =
      Trajectory.read_entries_since_result ~masc_root ~keeper_name:keeper
        ~since:0.0
    in
    Alcotest.(check int) "all entries" 3
      (List.length all.Trajectory.entries))

let test_read_entries_since_result_rejects_invalid_gate_rows () =
  with_tmpdir (fun dir ->
    let masc_root = dir in
    let keeper = "test-keeper" in
    let traj_dir = Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper) in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-101.jsonl" in
    let rows =
      [
        {|{"ts":1000.0,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":1,"tool_name":"tool_execute","args":{},"gate":{"status":"pass"},"result":"ok","duration_ms":100,"error":null}|};
        {|{"ts":2000.0,"ts_iso":"2026-04-06T10:01:00Z","turn":1,"round":2,"tool_name":"tool_execute","args":{},"gate":{"status":"reject","reason":"blocked"},"result":null,"duration_ms":0,"error":"blocked"}|};
        {|{"ts":3000.0,"ts_iso":"2026-04-06T10:02:00Z","turn":1,"round":3,"tool_name":"tool_execute","args":{},"result":"missing gate","duration_ms":10,"error":null}|};
      ]
    in
    let oc = open_out path in
    List.iter (Printf.fprintf oc "%s\n") rows;
    close_out oc;
    let result =
      Trajectory.read_entries_since_result ~masc_root ~keeper_name:keeper
        ~since:0.0
    in
    Alcotest.(check int) "invalid row excluded" 2
      (List.length result.Trajectory.entries);
    Alcotest.(check int) "passed gate count" 1
      result.Trajectory.gate_decode.passed_gate_count;
    Alcotest.(check int) "explicit rejected gate count" 1
      result.Trajectory.gate_decode.rejected_gate_count;
    Alcotest.(check int) "invalid row count" 1
      result.Trajectory.gate_decode.invalid_entry_count;
    Alcotest.(check int) "missing gate reason count" 1
      result.Trajectory.gate_decode.invalid_reasons.missing_gate;
    Alcotest.(check int) "no read errors" 0
      (List.length result.Trajectory.io_errors);
    match List.nth result.Trajectory.entries 1 with
    | { Trajectory.gate_decision = Trajectory.Reject reason; _ } ->
      Alcotest.(check string) "reject reason parsed" "blocked"
        (Trajectory.rejection_reason_to_string reason)
    | _ -> Alcotest.fail "expected persisted reject gate")

let test_read_entries_since_no_dir () =
  with_tmpdir (fun dir ->
    let result =
      Trajectory.read_entries_since_result ~masc_root:dir
        ~keeper_name:"nonexistent" ~since:0.0
    in
    Alcotest.(check int) "no dir" 0
      (List.length result.Trajectory.entries);
    Alcotest.(check int) "missing dir is not an I/O failure" 0
      (List.length result.Trajectory.io_errors))

(* P2 silent-failure fix: a malformed/corrupted row in the trajectory JSONL
   used to vanish from [read_recent_lines]/[read_all_lines] with zero
   signal (bare [List.filter_map] swallowing the parse exception). This
   pins the still-correct filtering behavior (malformed rows drop, valid
   rows survive) after switching to a fold that also tracks skipped/total
   for a per-read WARN summary (mirrors
   [Server_dashboard_http_keeper_api_trace.log_internal_history_skips]). *)
let write_raw_line ~masc_root ~keeper_name ~trace_id raw_line =
  let dir = Trajectory.trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = Trajectory.trajectory_path masc_root keeper_name trace_id in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () ->
    output_string oc raw_line;
    output_char oc '\n')

let test_read_recent_lines_skips_malformed_rows () =
  with_tmpdir (fun dir ->
    let acc =
      Trajectory.create_accumulator
        ~masc_root:dir ~keeper_name:"test-keeper" ~trace_id:"trace-malformed"
        ~generation:0 ()
    in
    Trajectory.record_entry acc
      (mk_entry "tool_execute" 10 "2026-07-01T00:00:00Z");
    Trajectory.flush_pending acc;
    write_raw_line ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-malformed" "{not valid json";
    let recent =
      Trajectory.read_recent_lines_result ~masc_root:dir
        ~keeper_name:"test-keeper"
        ~trace_id:"trace-malformed" ~max_lines:100
    in
    Alcotest.(check int)
      "malformed row dropped, valid row kept (read_recent_lines)"
      1
      (List.length recent.Trajectory.lines);
    Alcotest.(check int) "recent malformed row observed" 1
      recent.Trajectory.line_decode.invalid_reasons.malformed_json;
    let all_lines =
      Trajectory.read_all_lines_result ~masc_root:dir
        ~keeper_name:"test-keeper"
        ~trace_id:"trace-malformed"
    in
    Alcotest.(check int)
      "malformed row dropped, valid row kept (read_all_lines)"
      1
      (List.length all_lines.Trajectory.lines);
    Alcotest.(check int) "all-lines malformed row observed" 1
      all_lines.Trajectory.line_decode.invalid_reasons.malformed_json)

(* trajectory_summary rows are intentionally written to the same JSONL file at
   session end; they must not inflate the "malformed JSON or unrecognized
   shape" skip counter that the dashboard read paths log. *)
let test_summary_row_not_counted_as_malformed () =
  let lines =
    [
      {|{"ts":1000.0,"ts_iso":"2026-07-01T00:00:00Z","turn":1,"round":0,"tool_name":"tool_execute","args":{},"gate":{"status":"pass"},"result":"ok","duration_ms":10,"error":null}|}
    ; {|{"type":"trajectory_summary","keeper_name":"k","trace_id":"t","generation":0,"total_turns":0,"total_tool_calls":0,"outcome":{"status":"completed"},"started_at":0.0,"ended_at":0.0}|}
    ; "{not valid json"
    ]
  in
  let decoded =
    Trajectory.trajectory_lines_of_jsonl_lines lines
  in
  Alcotest.(check int) "parsed lines (tool call only)" 1
    (List.length decoded.Trajectory.lines);
  Alcotest.(check int) "summary explicitly skipped" 1
    decoded.Trajectory.line_decode.skipped_summary_count;
  Alcotest.(check int) "malformed row observed separately" 1
    decoded.Trajectory.line_decode.invalid_line_count

(* ================================================================ *)
(* Test: next_round tail-read hydration                              *)
(* ================================================================ *)

(* A trajectory JSONL row carrying the fields next_round reads. next_round only
   inspects the "turn" field, but the row mirrors a real tool-call entry. *)
let next_round_row ~turn ~round : Yojson.Safe.t =
  `Assoc
    [
      ("ts", `Float 1000.0);
      ("ts_iso", `String "2026-07-01T00:00:00Z");
      ("turn", `Int turn);
      ("round", `Int round);
      ("tool_name", `String "tool_execute");
      ("args", `Assoc []);
      ("gate", `Assoc [("status", `String "pass")]);
      ("result", `String "ok");
      ("duration_ms", `Int 1);
      ("error", `Null);
    ]

let next_round_summary_row : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "trajectory_summary");
      ("keeper_name", `String "k");
      ("trace_id", `String "t");
      ("generation", `Int 0);
    ]

(* Append rows to the trajectory JSONL for a keeper/trace. Uses a single append
   fd so the large-turn fixture stays fast, and appends (not truncates) so the
   cache-hit test can add rows after hydration. *)
let append_trajectory_rows ~masc_root ~keeper_name ~trace_id (rows : Yojson.Safe.t list) =
  let dir = Trajectory.trajectories_dir masc_root keeper_name in
  Fs_compat.mkdir_p dir;
  let path = Trajectory.trajectory_path masc_root keeper_name trace_id in
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      List.iter
        (fun row ->
          output_string oc (Yojson.Safe.to_string row);
          output_char oc '\n')
        rows)

let test_next_round_empty_or_missing_file () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    (* Missing file: first round is 1. *)
    let r_missing =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-missing" ~turn:1
    in
    Alcotest.(check int) "missing file -> round 1" 1 r_missing;
    (* Present but empty (0-byte) file: still round 1. *)
    let dir2 = Trajectory.trajectories_dir dir "k" in
    Fs_compat.mkdir_p dir2;
    let empty_path = Trajectory.trajectory_path dir "k" "t-empty" in
    close_out (open_out empty_path);
    let r_empty =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-empty"
        ~turn:1
    in
    Alcotest.(check int) "empty file -> round 1" 1 r_empty)

let test_next_round_past_turns_only () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-past"
      (List.init 5 (fun i -> next_round_row ~turn:3 ~round:i));
    (* No entries for turn 4 yet: first round is 1. *)
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-past"
        ~turn:4
    in
    Alcotest.(check int) "past turns only -> round 1" 1 r)

let test_next_round_counts_current_turn () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    let rows =
      List.init 2 (fun i -> next_round_row ~turn:6 ~round:i)
      @ List.init 3 (fun i -> next_round_row ~turn:7 ~round:i)
    in
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cur" rows;
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cur"
        ~turn:7
    in
    Alcotest.(check int) "3 current-turn entries -> round 4" 4 r)

let test_next_round_ignores_summary_rows_without_turn () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-summary"
      [
        next_round_row ~turn:7 ~round:0;
        next_round_row ~turn:7 ~round:1;
        next_round_summary_row;
      ];
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-summary" ~turn:7
    in
    Alcotest.(check int) "summary row skipped -> round 3" 3 r)

let test_next_round_widens_past_initial_window () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    (* 600 current-turn rows (> the 512-line initial tail window, < 1024) sit
       above a 3-row previous-turn boundary. The first tail read misses the
       boundary; the window must widen once to count exactly. *)
    let current_count = 600 in
    let rows =
      List.init 3 (fun i -> next_round_row ~turn:9 ~round:i)
      @ List.init current_count (fun i -> next_round_row ~turn:10 ~round:i)
    in
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-wide" rows;
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-wide"
        ~turn:10
    in
    Alcotest.(check int) "600 current-turn entries -> round 601"
      (current_count + 1) r)

let test_next_round_full_scan_fallback () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    (* Single-turn file larger than the tail cap (currently 8192 lines) with no
       older-turn boundary anywhere. Forces the doubling loop to the cap and
       then the full-scan fallback; the count must still be exact. 9000 is
       chosen to exceed the internal max_hydrate_tail_lines constant. *)
    let current_count = 9000 in
    let rows = List.init current_count (fun i -> next_round_row ~turn:1 ~round:i) in
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-huge" rows;
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-huge"
        ~turn:1
    in
    Alcotest.(check int) "9000 current-turn entries via full-scan -> round 9001"
      (current_count + 1) r)

let test_next_round_cache_hit_skips_disk () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
      [ next_round_row ~turn:2 ~round:0; next_round_row ~turn:2 ~round:1 ];
    let r1 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
        ~turn:2
    in
    Alcotest.(check int) "hydrate 2 rows -> round 3" 3 r1;
    (* Append two more turn-2 rows AFTER hydration; a cache hit must ignore the
       disk and increment purely in memory. *)
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
      [ next_round_row ~turn:2 ~round:9; next_round_row ~turn:2 ~round:9 ];
    let r2 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
        ~turn:2
    in
    Alcotest.(check int) "cache hit ignores new disk rows -> round 4" 4 r2)

let test_next_round_evicts_past_turn_keys () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
      [ next_round_row ~turn:5 ~round:0; next_round_row ~turn:5 ~round:1 ];
    let r5a =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:5
    in
    Alcotest.(check int) "turn 5 hydrate -> round 3" 3 r5a;
    let r5b =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:5
    in
    Alcotest.(check int) "turn 5 cache hit -> round 4" 4 r5b;
    (* Advancing to turn 6 evicts the turn-5 cache key. *)
    let r6 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:6
    in
    Alcotest.(check int) "turn 6 first round -> 1" 1 r6;
    (* The active turn-5 key was evicted, but the issued high-water mark is
       retained so an out-of-order caller cannot receive a duplicate round. *)
    let r5c =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:5
    in
    Alcotest.(check int) "turn 5 after eviction stays monotonic" 5 r5c)

let thinking_line ?(ts = 1000.0) ?(redacted = false) content =
  Trajectory.Thinking
    {
      ts;
      ts_iso = "2026-06-29T00:00:00Z";
      turn = 1;
      content;
      content_length = String.length content;
      redacted;
    }

let check_thinking_content label expected = function
  | Trajectory.Thinking entry ->
      Alcotest.(check string) label expected entry.Trajectory.content
  | Trajectory.Tool_call _ -> Alcotest.fail (label ^ ": expected thinking line")

let check_tool_call label expected = function
  | Trajectory.Tool_call entry ->
      Alcotest.(check string) label expected entry.Trajectory.tool_name
  | Trajectory.Thinking _ -> Alcotest.fail (label ^ ": expected tool call line")

let test_dedupe_thinking_lines_uses_structural_key () =
  let tool_call =
    Trajectory.Tool_call
      (mk_entry ~ts:1000.5 "tool_execute" 20 "2026-06-29T00:00:00Z")
  in
  let lines =
    [
      thinking_line ~ts:1000.0 "same";
      tool_call;
      thinking_line ~ts:1000.0 "same";
      thinking_line ~ts:1001.0 "same";
      thinking_line ~ts:1000.0 ~redacted:true "same";
    ]
  in
  let deduped =
    Server_dashboard_http_keeper_api_trace.dedupe_thinking_lines lines
  in
  Alcotest.(check int) "one exact duplicate removed" 4 (List.length deduped);
  check_thinking_content "first thinking preserved" "same" (List.nth deduped 0);
  check_tool_call "tool call preserved" "tool_execute" (List.nth deduped 1);
  check_thinking_content "same content at a new timestamp preserved" "same"
    (List.nth deduped 2);
  (match List.nth deduped 3 with
   | Trajectory.Thinking entry ->
       Alcotest.(check bool) "redacted variant preserved" true entry.Trajectory.redacted
   | Trajectory.Tool_call _ -> Alcotest.fail "expected redacted thinking line")

(* ================================================================ *)
(* Runner                                                            *)
(* ================================================================ *)

(* ================================================================ *)
(* Test: thinking trajectory — full untruncated text, per-turn        *)
(* ================================================================ *)

let read_thinking_jsonl ~masc_root ~keeper_name ~trace_id =
  let path = Filename.concat masc_root
    (Printf.sprintf "trajectories/%s/%s.jsonl" keeper_name trace_id) in
  if not (Sys.file_exists path) then []
  else begin
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      let rec loop acc =
        match input_line ic with
        | line -> loop (Yojson.Safe.from_string line :: acc)
        | exception End_of_file -> List.rev acc
      in
      loop [])
  end

(* append_thinking persists the complete text supplied by the caller. *)
let test_append_thinking_persists_untruncated () =
  with_tmpdir (fun dir ->
    let big = String.make 9000 'x' in
    let entry : Trajectory.thinking_entry = {
      ts = 1000.0; ts_iso = "2026-06-09T00:00:00Z"; turn = 4;
      content = big; content_length = String.length big; redacted = false;
    } in
    Trajectory.append_thinking ~masc_root:dir ~keeper_name:"k" ~trace_id:"th1" entry;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th1" in
    Alcotest.(check int) "one thinking line" 1 (List.length lines);
    let open Yojson.Safe.Util in
    let row = List.hd lines in
    Alcotest.(check string) "type=thinking" "thinking" (row |> member "type" |> to_string);
    Alcotest.(check int) "content untruncated (9000B, not 2000 cap)" 9000
      (row |> member "content" |> to_string |> String.length);
    Alcotest.(check int) "content_length records true length" 9000
      (row |> member "content_length" |> to_int))

(* persist_response_content stamps every block with the hook's ~turn (not
   acc.turn) and writes one line per thinking block, untruncated. *)
let test_persist_response_content_per_turn_full () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" ~generation:0 () in
    (* acc.turn stays 0; the hook passes ~turn:11 — assert ~turn wins. *)
    let big = String.make 5000 'a' in
    let content = [
      Agent_sdk.Types.Thinking { signature = None; content = big };
      Agent_sdk.Types.Thinking { signature = None; content = "second block" };
    ] in
    Keeper_agent_run_thinking_trajectory.persist_response_content
      ~keeper_name:"k" ~trajectory_acc:(Some acc) ~turn:11 content;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "both thinking blocks persisted" 2 (List.length lines);
    List.iter (fun row ->
      Alcotest.(check int) "turn stamped from hook (11), not acc.turn (0)" 11
        (row |> member "turn" |> to_int)) lines;
    Alcotest.(check int) "first block untruncated (5000B)" 5000
      (List.hd lines |> member "content" |> to_string |> String.length))

let () =
  Alcotest.run "Trajectory" [
    ("gate_decision", [
      Alcotest.test_case "pass" `Quick test_gate_decision_pass;
      Alcotest.test_case "reject" `Quick test_gate_decision_reject;
    ]);
    ("accumulator", [
      Alcotest.test_case "create" `Quick test_create_accumulator;
      Alcotest.test_case "record_entry" `Quick test_record_entry;
      Alcotest.test_case "increment_turn" `Quick test_increment_turn;
      Alcotest.test_case "calls_in_current_turn" `Quick test_calls_in_current_turn;
    ]);
    ("finalize", [
      Alcotest.test_case "finalize completed" `Quick test_finalize;
    ]);
    ("outcome", [
      Alcotest.test_case "outcome_to_string" `Quick test_outcome_to_string;
    ]);
    ("aggregate_tool_stats", [
      Alcotest.test_case "basic aggregation" `Quick test_aggregate_basic;
      Alcotest.test_case "with errors and rejected gates" `Quick test_aggregate_with_errors;
      Alcotest.test_case "empty input" `Quick test_aggregate_empty;
      Alcotest.test_case "p95 calculation" `Quick test_aggregate_p95;
    ]);
    ("hourly_timeline", [
      Alcotest.test_case "single bucket" `Quick test_hourly_single_bucket;
      Alcotest.test_case "with errors" `Quick test_hourly_with_errors;
      Alcotest.test_case "empty input" `Quick test_hourly_empty;
    ]);
    ("json_serialization", [
      Alcotest.test_case "tool_stat to json" `Quick test_tool_stat_json_roundtrip;
      Alcotest.test_case "hourly_bucket to json" `Quick test_hourly_bucket_json;
      Alcotest.test_case "entry preserves typed fields" `Quick
        test_entry_to_json_preserves_typed_fields;
      Alcotest.test_case "execution_id JSONL round-trip + optional None" `Quick
        test_execution_id_roundtrip;
      Alcotest.test_case "gate codec rejects noncanonical rows" `Quick
        test_gate_codec_rejects_noncanonical_rows;
      Alcotest.test_case "closed row codec rejects invalid fields and types"
        `Quick test_closed_row_codec_rejects_invalid_fields_and_types;
    ]);
    ("next_round", [
      Alcotest.test_case "empty or missing file -> 1" `Quick
        test_next_round_empty_or_missing_file;
      Alcotest.test_case "past turns only -> 1" `Quick
        test_next_round_past_turns_only;
      Alcotest.test_case "counts current-turn entries" `Quick
        test_next_round_counts_current_turn;
      Alcotest.test_case "ignores summary rows without turn" `Quick
        test_next_round_ignores_summary_rows_without_turn;
      Alcotest.test_case "widens window past initial 512" `Quick
        test_next_round_widens_past_initial_window;
      Alcotest.test_case "full-scan fallback past cap" `Quick
        test_next_round_full_scan_fallback;
      Alcotest.test_case "cache hit skips disk" `Quick
        test_next_round_cache_hit_skips_disk;
      Alcotest.test_case "evicts past-turn keys" `Quick
        test_next_round_evicts_past_turn_keys;
    ]);
    ("read_entries_since", [
      Alcotest.test_case "filter by timestamp" `Quick test_read_entries_since;
      Alcotest.test_case "rejects invalid gate rows" `Quick
        test_read_entries_since_result_rejects_invalid_gate_rows;
      Alcotest.test_case "nonexistent directory" `Quick test_read_entries_since_no_dir;
      Alcotest.test_case "read_recent_lines/read_all_lines skip malformed rows" `Quick
        test_read_recent_lines_skips_malformed_rows;
      Alcotest.test_case "summary row not counted as malformed" `Quick
        test_summary_row_not_counted_as_malformed;
    ]);
    ("keeper_trace", [
      Alcotest.test_case "dedupe_thinking_lines uses structural key" `Quick
        test_dedupe_thinking_lines_uses_structural_key;
    ]);
    ("thinking_trajectory", [
      Alcotest.test_case "append_thinking persists full untruncated text" `Quick
        test_append_thinking_persists_untruncated;
      Alcotest.test_case "persist_response_content stamps hook turn, all blocks" `Quick
        test_persist_response_content_per_turn_full;
    ]);
  ]
