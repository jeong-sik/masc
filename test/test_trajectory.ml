(** Unit tests for Trajectory module — JSONL trajectory logging. *)

open Masc

let () =
  (* Ensure RNG is initialized for any code that may need it *)
  ignore (Unix.gettimeofday ())

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

let make_tool_entry ~ts ~ts_iso ~turn ~round ~tool_name ~arguments ~outcome
    ~duration_ms ~execution_id =
  match
    Trajectory.make_tool_call_entry ~ts ~ts_iso ~turn ~round ~tool_name
      ~arguments ~outcome ~duration_ms ~execution_id
  with
  | Ok entry -> entry
  | Error error ->
      Alcotest.failf "invalid Tool fixture: %s"
        (Trajectory.entry_decode_error_to_string error)

let test_create_accumulator () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-001" ~generation:0 () in
    Alcotest.(check int) "initial entries" 0
      (List.length (Trajectory.accumulator_entries acc)))

let test_duplicate_active_accumulator_is_rejected () =
  with_tmpdir (fun dir ->
    let first =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
        ~trace_id:"trace-duplicate" ~generation:0 ()
    in
    (match
       Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
         ~trace_id:"trace-duplicate" ~generation:0 ()
     with
     | _ -> Alcotest.fail "duplicate active accumulator must not replace SSOT"
     | exception
         Trajectory.Accumulator_registration_error
           (Trajectory.Active_accumulator_exists _) -> ());
    Trajectory.finalize first Trajectory.Completed |> ignore)

(* ================================================================ *)
(* Test: record_entry updates accumulator                            *)
(* ================================================================ *)

let test_record_entry () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-002" ~generation:0 () in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-01-01T00:00:00Z" ~turn:1
        ~round:1 ~tool_name:"tool_execute"
        ~arguments:[ "command", `String "pwd" ]
        ~outcome:(Trajectory.Tool_succeeded "/home/test") ~duration_ms:50
        ~execution_id:"exec-1000-0001"
    in
    Trajectory.record_entry acc entry;
    Alcotest.(check int) "entries count" 1
      (List.length (Trajectory.accumulator_entries acc)))

(* ================================================================ *)
(* Test: finalize creates trajectory record                          *)
(* ================================================================ *)

let test_finalize () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-006" ~generation:0 () in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-01-01T00:00:00Z" ~turn:1
        ~round:1 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:100
        ~execution_id:"exec-finalize-1"
    in
    Trajectory.record_entry acc entry;
    let thinking =
      match
        Trajectory.make_thinking_entry ~ts:1001.0
          ~ts_iso:"2026-01-01T00:00:01Z" ~turn:2 ~block_index:0
          ~block:
            (Agent_sdk.Types.Thinking
               { content = "second observed turn"; signature = None })
      with
      | Ok entry -> entry
      | Error error ->
          Alcotest.failf "invalid Thinking fixture: %s"
            (Trajectory.entry_decode_error_to_string error)
    in
    Trajectory.record_thinking acc thinking;
    let traj = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check int) "distinct observed turns" 2
      traj.Trajectory.total_turns;
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
(* Test: aggregate_tool_stats                                        *)
(* ================================================================ *)

let mk_entry ?(ts = 1000.0) ?(error = None) name dur ts_iso =
  make_tool_entry ~ts ~ts_iso ~turn:1 ~round:1 ~tool_name:name ~arguments:[]
    ~outcome:
      (match error with
       | None -> Trajectory.Tool_succeeded "ok"
       | Some message -> Trajectory.Tool_failed message)
    ~duration_ms:dur ~execution_id:(Printf.sprintf "exec-%s-%d" name dur)

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
    mk_entry ~error:(Some "denied") "tool_execute" 0
      "2026-04-06T10:02:00Z";
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
    mk_entry ~ts:1743937500.0 "tool_execute" 100 "2026-04-06T10:05:00Z";
    mk_entry ~ts:1743939000.0 "tool_execute" 100 "2026-04-06T10:30:00Z";
  ] in
  let timeline = Trajectory.hourly_timeline entries in
  (* Both entries fall in the same hour bucket (25 min apart) *)
  Alcotest.(check int) "bucket count" 1 (List.length timeline);
  let b = List.hd timeline in
  Alcotest.(check int) "call count" 2 b.Trajectory.call_count;
  Alcotest.(check int) "error count" 0 b.Trajectory.error_count

let test_hourly_with_errors () =
  let entries = [
    mk_entry ~ts:1743937500.0 "tool_execute" 100 "2026-04-06T10:05:00Z";
    mk_entry ~ts:1743939000.0 ~error:(Some "fail") "tool_execute" 100
      "2026-04-06T10:30:00Z";
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
  let entry =
    make_tool_entry ~ts:1000.0 ~ts_iso:"2026-04-06T10:00:00Z" ~turn:1
      ~round:1 ~tool_name:"tool_execute"
      ~arguments:[ "command", `String "pwd" ]
      ~outcome:(Trajectory.Tool_succeeded "/tmp/work") ~duration_ms:25
      ~execution_id:"exec-1000-0001"
  in
  let json = Trajectory.entry_to_json entry in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "structured argument" "pwd"
    (json |> member "args" |> member "command" |> to_string);
  Alcotest.(check string) "execution_id persisted" "exec-1000-0001"
    (json |> member "execution_id" |> to_string)

(* The canonical join key is required. Rows without it are invalid rather than
   guessed from timestamps, names, or durations. *)
let test_execution_id_roundtrip () =
  let entry =
    make_tool_entry ~ts:1000.0 ~ts_iso:"2026-06-12T00:00:00Z" ~turn:3
      ~round:1 ~tool_name:"tool_execute" ~arguments:[]
      ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:10
      ~execution_id:"exec-1718150400000-0001"
  in
  (match Trajectory.tool_call_entry_of_json (Trajectory.entry_to_json entry) with
   | Trajectory.Decoded_entry decoded ->
       Alcotest.(check string) "round-trip"
         "exec-1718150400000-0001" decoded.Trajectory.execution_id
   | Trajectory.Non_entry_row | Trajectory.Invalid_entry _ ->
       Alcotest.fail "entry did not decode");
  let without_execution_id =
    match Trajectory.entry_to_json entry with
    | `Assoc fields -> `Assoc (List.remove_assoc "execution_id" fields)
    | _ -> Alcotest.fail "entry serializer must return an object"
  in
  match Trajectory.tool_call_entry_of_json without_execution_id with
  | Trajectory.Invalid_entry
      (Trajectory.Missing_required_field Trajectory.Execution_id) -> ()
  | Trajectory.Decoded_entry _ | Trajectory.Non_entry_row
  | Trajectory.Invalid_entry _ ->
      Alcotest.fail "entry without execution_id must be rejected"

let test_retired_gate_field_is_rejected () =
  let canonical =
    Trajectory.entry_to_json
      (mk_entry "tool_execute" 1 "2026-06-12T00:00:00Z")
  in
  let with_retired_gate =
    match canonical with
    | `Assoc fields ->
        `Assoc (("gate", `Assoc [("status", `String "pass")]) :: fields)
    | _ -> Alcotest.fail "entry serializer must return an object"
  in
  match Trajectory.tool_call_entry_of_json with_retired_gate with
  | Trajectory.Invalid_entry (Trajectory.Unexpected_field "gate") -> ()
  | _ -> Alcotest.fail "retired gate field must not remain a hidden legacy input"

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
  check_invalid_field Trajectory.Round (replace "round" (`Int 0) valid_entry);
  check_invalid_field Trajectory.Tool_name
    (replace "tool_name" (`String "") valid_entry);
  check_invalid_field Trajectory.Duration_ms
    (replace "duration_ms" (`Int (-1)) valid_entry);
  check_invalid_field Trajectory.Arguments
    (replace "args" (`String "{}") valid_entry);
  check_invalid_field Trajectory.Tool_outcome
    (replace "outcome" (`Assoc [("status", `String "unknown")]) valid_entry);
  (match
     Trajectory.tool_call_entry_of_json
       (replace "type" (`String "unsupported") valid_entry)
   with
   | Trajectory.Invalid_entry
       (Trajectory.Unsupported_row_type "unsupported") -> ()
   | _ -> Alcotest.fail "unknown row type must not decode as a tool row");
  let invalid_thinking =
    {|{"type":"thinking","ts":1000.0,"ts_iso":"2026-06-12T00:00:00Z","turn":1,"block_index":0,"block":{"type":"thinking","thinking":"thought"},"unexpected":false}|}
  in
  let decoded =
    Trajectory.trajectory_lines_of_jsonl_lines [ invalid_thinking ]
  in
  Alcotest.(check int) "invalid thinking excluded" 0
    (List.length decoded.Trajectory.lines);
  Alcotest.(check int) "invalid thinking observed" 1
    decoded.Trajectory.line_decode.invalid_line_count;
  Alcotest.(check int) "unexpected thinking field reason" 1
    decoded.Trajectory.line_decode.invalid_reasons.unexpected_field

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
      {|{"ts":%.1f,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":1,"tool_name":"tool_execute","args":{},"outcome":{"status":"succeeded","output":"ok"},"duration_ms":100,"execution_id":"exec-read-%.0f"}|}
      ts
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
    Alcotest.(check int) "no invalid filtered rows" 0
      entries.Trajectory.decode.invalid_entry_count;
    Alcotest.(check int) "no read errors" 0
      (List.length entries.Trajectory.io_errors);
    (* Read since ts=0 should get all 3 *)
    let all =
      Trajectory.read_entries_since_result ~masc_root ~keeper_name:keeper
        ~since:0.0
    in
    Alcotest.(check int) "all entries" 3
      (List.length all.Trajectory.entries))

let test_read_entries_since_result_rejects_retired_fields () =
  with_tmpdir (fun dir ->
    let masc_root = dir in
    let keeper = "test-keeper" in
    let traj_dir = Filename.concat masc_root (Printf.sprintf "trajectories/%s" keeper) in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-101.jsonl" in
    let rows =
      [
        {|{"ts":1000.0,"ts_iso":"2026-04-06T10:00:00Z","turn":1,"round":1,"tool_name":"tool_execute","args":{},"outcome":{"status":"succeeded","output":"ok"},"duration_ms":100,"execution_id":"exec-read-1"}|};
        {|{"ts":2000.0,"ts_iso":"2026-04-06T10:01:00Z","turn":1,"round":2,"tool_name":"tool_execute","args":{},"outcome":{"status":"failed","error":"blocked"},"duration_ms":0,"execution_id":"exec-read-2"}|};
        {|{"ts":3000.0,"ts_iso":"2026-04-06T10:02:00Z","turn":1,"round":3,"tool_name":"tool_execute","args":{},"gate":{"status":"pass"},"outcome":{"status":"succeeded","output":"legacy"},"duration_ms":10,"execution_id":"exec-read-3"}|};
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
    Alcotest.(check int) "invalid row count" 1
      result.Trajectory.decode.invalid_entry_count;
    Alcotest.(check int) "retired field reason count" 1
      result.Trajectory.decode.invalid_reasons.unexpected_field;
    Alcotest.(check int) "no read errors" 0
      (List.length result.Trajectory.io_errors))

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
   rows survive) after switching to a fold that also tracks exact invalid
   reasons for the read result. *)
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
        ~trace_id:"trace-malformed" ~max_entries:100
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
      all_lines.Trajectory.line_decode.invalid_reasons.malformed_json;
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let trajectory_tool_row ~ts ~round ~execution_id =
  make_tool_entry ~ts ~ts_iso:"2026-07-01T00:00:00Z" ~turn:1 ~round
    ~tool_name:"tool_execute" ~arguments:[]
    ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:1 ~execution_id
  |> Trajectory.entry_to_json
  |> Yojson.Safe.to_string

let trajectory_thinking_row =
  {|{"type":"thinking","ts":1001.0,"ts_iso":"2026-07-01T00:00:01Z","turn":1,"block_index":0,"block":{"type":"thinking","thinking":"exact reasoning"}}|}

let trajectory_summary_row =
  {|{"type":"trajectory_summary","keeper_name":"test-keeper","trace_id":"trace-page","generation":0,"total_turns":1,"total_tool_calls":2,"outcome":"completed","started_at":1000.0,"ended_at":1002.0}|}

let test_recent_limit_counts_only_canonical_entries () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-decoded-limit" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~round:1 ~execution_id:"exec-oldest");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "{not valid json";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_summary_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_thinking_row;
    let result =
      Trajectory.read_recent_lines_result ~masc_root:dir ~keeper_name ~trace_id
        ~max_entries:2
    in
    (match result.Trajectory.lines with
     | [ Trajectory.Tool_call tool; Trajectory.Thinking thinking ] ->
         Alcotest.(check string) "oldest canonical Tool"
           "exec-oldest" tool.Trajectory.execution_id;
         Alcotest.(check int) "newest canonical Thinking index"
           0 thinking.Trajectory.block_index
     | lines ->
         Alcotest.failf "expected Tool + Thinking, got %d canonical rows"
           (List.length lines));
    Alcotest.(check int) "canonical Tool count" 1
      result.Trajectory.line_decode.tool_call_count;
    Alcotest.(check int) "canonical Thinking count" 1
      result.Trajectory.line_decode.thinking_count;
    Alcotest.(check int) "summary observed without consuming limit" 1
      result.Trajectory.line_decode.skipped_summary_count;
    Alcotest.(check int) "invalid row observed without consuming limit" 1
      result.Trajectory.line_decode.invalid_line_count)

let test_recent_page_cursor_is_exact_and_snapshot_bound () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-page" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~round:1 ~execution_id:"exec-page-1");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_thinking_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "{not valid json";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_summary_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1002.0 ~round:2 ~execution_id:"exec-page-2");
    let newest =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~max_entries:2 ()
    in
    (match newest.Trajectory.read.lines with
     | [ Trajectory.Thinking _; Trajectory.Tool_call tool ] ->
         Alcotest.(check string) "newest Tool identity"
           "exec-page-2" tool.Trajectory.execution_id
     | lines ->
         Alcotest.failf "expected Thinking + newest Tool, got %d rows"
           (List.length lines));
    Alcotest.(check int) "page observes summary" 1
      newest.Trajectory.read.line_decode.skipped_summary_count;
    Alcotest.(check int) "page observes malformed row" 1
      newest.Trajectory.read.line_decode.invalid_line_count;
    let cursor =
      match newest.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "older canonical row requires a cursor"
    in
    Alcotest.(check bool) "cursor is a positive byte boundary" true
      (Trajectory.trajectory_byte_cursor_offset cursor > 0L);
    (* Appends after the first page do not move its cursor into the new suffix. *)
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1003.0 ~round:3 ~execution_id:"exec-later");
    let older =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~max_entries:2 ()
    in
    (match older.Trajectory.read.lines with
     | [ Trajectory.Tool_call tool ] ->
         Alcotest.(check string) "older page Tool identity"
           "exec-page-1" tool.Trajectory.execution_id
     | lines ->
         Alcotest.failf "expected one older Tool, got %d rows"
           (List.length lines));
    Alcotest.(check bool) "beginning of snapshot has no next cursor" true
      (Option.is_none older.Trajectory.next_cursor);
    Alcotest.(check int) "cursor page has no storage error" 0
      (List.length older.Trajectory.read.io_errors))

let test_recent_page_cursor_rejects_truncated_snapshot () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-truncated-cursor" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~round:1 ~execution_id:"exec-truncate-1");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1001.0 ~round:2 ~execution_id:"exec-truncate-2");
    let first =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~max_entries:1 ()
    in
    let cursor =
      match first.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "first page must expose its older byte boundary"
    in
    Unix.truncate (Trajectory.trajectory_path dir keeper_name trace_id) 0;
    let rejected =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~max_entries:1 ()
    in
    Alcotest.(check int) "truncated page has no fabricated rows" 0
      (List.length rejected.Trajectory.read.lines);
    Alcotest.(check int) "truncation is an explicit storage error" 1
      (List.length rejected.Trajectory.read.io_errors);
    Alcotest.(check bool) "failed page has no continuation cursor" true
      (Option.is_none rejected.Trajectory.next_cursor))

let test_recent_reader_scans_unbounded_non_entry_suffix () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-long-summary-suffix" in
    let trajectory_dir = Trajectory.trajectories_dir dir keeper_name in
    Fs_compat.mkdir_p trajectory_dir;
    let path = Trajectory.trajectory_path dir keeper_name trace_id in
    let output = open_out_bin path in
    Fun.protect
      ~finally:(fun () -> close_out output)
      (fun () ->
         output_string output
           (trajectory_tool_row ~ts:1000.0 ~round:1
              ~execution_id:"exec-long-1");
         output_char output '\n';
         output_string output
           (trajectory_tool_row ~ts:1001.0 ~round:2
              ~execution_id:"exec-long-2");
         output_char output '\n';
         for _ = 1 to 12_000 do
           output_string output trajectory_summary_row;
           output_char output '\n'
         done);
    let result =
      Trajectory.read_recent_lines_result ~masc_root:dir ~keeper_name ~trace_id
        ~max_entries:2
    in
    Alcotest.(check int) "canonical rows beyond summary suffix" 2
      (List.length result.Trajectory.lines);
    Alcotest.(check int) "all trailing summaries observed" 12_000
      result.Trajectory.line_decode.skipped_summary_count;
    Alcotest.(check int) "no storage errors" 0
      (List.length result.Trajectory.io_errors))

(* trajectory_summary rows are intentionally written to the same JSONL file at
   session end; they must not inflate the "malformed JSON or unrecognized
   shape" skip counter that the dashboard read paths log. *)
let test_summary_row_not_counted_as_malformed () =
  let lines =
    [
      {|{"ts":1000.0,"ts_iso":"2026-07-01T00:00:00Z","turn":1,"round":1,"tool_name":"tool_execute","args":{},"outcome":{"status":"succeeded","output":"ok"},"duration_ms":10,"execution_id":"exec-summary-1"}|}
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

(* A complete canonical Tool row for round hydration. *)
let next_round_row ~turn ~round : Yojson.Safe.t =
  `Assoc
    [
      ("ts", `Float 1000.0);
      ("ts_iso", `String "2026-07-01T00:00:00Z");
      ("turn", `Int turn);
      ("round", `Int round);
      ("tool_name", `String "tool_execute");
      ("args", `Assoc []);
      ("outcome", `Assoc [("status", `String "succeeded"); ("output", `String "ok")]);
      ("duration_ms", `Int 1);
      ("execution_id", `String (Printf.sprintf "exec-round-%d-%d" turn round));
    ]

let next_round_summary_row : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String "trajectory_summary");
      ("keeper_name", `String "k");
      ("trace_id", `String "t");
      ("generation", `Int 0);
    ]

let next_round_thinking_row ~turn : Yojson.Safe.t =
  `Assoc
    [ ("type", `String "thinking")
    ; ("ts", `Float 1000.0)
    ; ("ts_iso", `String "2026-07-01T00:00:00Z")
    ; ("turn", `Int turn)
    ; ("block_index", `Int 0)
    ; ( "block"
      , `Assoc
          [ ("type", `String "thinking")
          ; ("thinking", `String "reasoning")
          ] )
    ]

(* Append complete fixture rows to one trajectory JSONL. *)
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
      (List.init 5 (fun index -> next_round_row ~turn:3 ~round:(index + 1)));
    (* No entries for turn 4 yet: first round is 1. *)
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-past"
        ~turn:4
    in
    Alcotest.(check int) "past turns only -> round 1" 1 r)

let test_next_round_hydrates_latest_current_round () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    let rows =
      List.init 2 (fun index -> next_round_row ~turn:6 ~round:(index + 1))
      @ List.init 3 (fun index -> next_round_row ~turn:7 ~round:(index + 1))
    in
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cur" rows;
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cur"
        ~turn:7
    in
    Alcotest.(check int) "latest current round 3 -> round 4" 4 r)

let test_next_round_concurrent_cold_miss_is_unique () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k"
      ~trace_id:"t-concurrent"
      (List.init 3 (fun index -> next_round_row ~turn:7 ~round:(index + 1)));
    let issue () =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-concurrent" ~turn:7
    in
    let peer = Domain.spawn issue in
    let local = issue () in
    let issued = List.sort Int.compare [ local; Domain.join peer ] in
    Alcotest.(check (list int)) "concurrent cold miss allocates unique rounds"
      [ 4; 5 ] issued)

let test_next_round_ignores_summary_rows_without_turn () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-summary"
      [
        next_round_row ~turn:7 ~round:1;
        next_round_row ~turn:7 ~round:2;
        next_round_summary_row;
      ];
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-summary" ~turn:7
    in
    Alcotest.(check int) "summary row skipped -> round 3" 3 r)

let test_next_round_skips_thinking_rows () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k"
      ~trace_id:"t-thinking"
      [ next_round_row ~turn:7 ~round:1
      ; next_round_thinking_row ~turn:7
      ; next_round_row ~turn:7 ~round:2
      ];
    let round =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-thinking" ~turn:7
    in
    Alcotest.(check int) "Thinking row does not replace latest Tool round" 3
      round)

let test_next_round_isolated_by_masc_root () =
  with_tmpdir (fun first_root ->
    with_tmpdir (fun second_root ->
      Trajectory.reset_round_counters_for_testing ();
      append_trajectory_rows ~masc_root:first_root ~keeper_name:"k"
        ~trace_id:"same-trace"
        (List.init 2 (fun index ->
             next_round_row ~turn:4 ~round:(index + 1)));
      append_trajectory_rows ~masc_root:second_root ~keeper_name:"k"
        ~trace_id:"same-trace"
        (List.init 5 (fun index ->
             next_round_row ~turn:4 ~round:(index + 1)));
      let first =
        Trajectory.next_round ~masc_root:first_root ~keeper_name:"k"
          ~trace_id:"same-trace" ~turn:4
      in
      let second =
        Trajectory.next_round ~masc_root:second_root ~keeper_name:"k"
          ~trace_id:"same-trace" ~turn:4
      in
      Alcotest.(check int) "first base hydrates independently" 3 first;
      Alcotest.(check int) "second base hydrates independently" 6 second))

let test_next_round_uses_latest_persisted_round () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-gap"
      [ next_round_row ~turn:10 ~round:3
      ; next_round_row ~turn:10 ~round:7
      ];
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-gap"
        ~turn:10
    in
    Alcotest.(check int) "persisted round is authority, not row count" 8 r)

let test_next_round_searches_past_non_tool_suffix () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-suffix"
      [ next_round_row ~turn:1 ~round:4
      ; next_round_thinking_row ~turn:1
      ; next_round_summary_row
      ];
    let r =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"t-suffix"
        ~turn:1
    in
    Alcotest.(check int) "non-Tool suffix does not become a Tool round" 5 r)

let test_next_round_active_allocator_is_monotonic () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
      [ next_round_row ~turn:2 ~round:1; next_round_row ~turn:2 ~round:2 ];
    let r1 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
        ~turn:2
    in
    Alcotest.(check int) "hydrate 2 rows -> round 3" 3 r1;
    let r2 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-cache"
        ~turn:2
    in
    Alcotest.(check int) "active allocator increments in memory -> round 4" 4 r2)

let test_next_round_evicts_past_turn_keys () =
  with_tmpdir (fun dir ->
    Trajectory.reset_round_counters_for_testing ();
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
      [ next_round_row ~turn:5 ~round:1; next_round_row ~turn:5 ~round:2 ];
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
    append_trajectory_rows ~masc_root:dir ~keeper_name:"k"
      ~trace_id:"t-evict"
      [ next_round_row ~turn:5 ~round:3
      ; next_round_row ~turn:5 ~round:4
      ];
    (* Advancing to turn 6 evicts the turn-5 cache key. *)
    let r6 =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:6
    in
    Alcotest.(check int) "turn 6 first round -> 1" 1 r6;
    (* The active turn-5 key was evicted. A late caller rehydrates the durable
       round 4 rather than retaining an unbounded per-turn high-water table. *)
    let r5c =
      Trajectory.next_round ~masc_root:dir ~keeper_name:"k" ~trace_id:"t-evict"
        ~turn:5
    in
    Alcotest.(check int) "turn 5 after eviction stays monotonic" 5 r5c)

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

let test_tool_results_are_persisted_untruncated () =
  with_tmpdir (fun dir ->
    let result = String.make 12000 'r' in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-07-18T00:00:00Z" ~turn:1
        ~round:1 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded result) ~duration_ms:10
        ~execution_id:"exec-lossless-1"
    in
    Trajectory.record_tool_call ~masc_root:dir ~keeper_name:"k"
      ~trace_id:"tool-direct" entry;
    let direct =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"tool-direct"
    in
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"tool-batched" ~generation:0 ()
    in
    let batched_entry =
      make_tool_entry ~ts:entry.ts ~ts_iso:entry.ts_iso ~turn:entry.turn
        ~round:entry.round ~tool_name:entry.tool_name
        ~arguments:entry.arguments ~outcome:entry.outcome
        ~duration_ms:entry.duration_ms ~execution_id:"exec-lossless-2"
    in
    Trajectory.record_entry acc batched_entry;
    Trajectory.flush_pending acc;
    let batched =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"tool-batched"
    in
    let open Yojson.Safe.Util in
    let persisted_result rows =
      match rows with
      | [ row ] -> row |> member "outcome" |> member "output" |> to_string
      | _ -> Alcotest.fail "expected exactly one persisted tool row"
    in
    Alcotest.(check string) "direct append is lossless" result
      (persisted_result direct);
    Alcotest.(check string) "batched append is lossless" result
      (persisted_result batched);
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let test_finalize_retries_complete_batch_after_write_failure () =
  with_tmpdir (fun dir ->
    let blocked_parent = Filename.concat dir "trajectories" in
    let oc = open_out blocked_parent in
    close_out oc;
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"retry-finalize" ~generation:0 ()
    in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-07-18T00:00:00Z" ~turn:1
        ~round:1 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "durable") ~duration_ms:10
        ~execution_id:"exec-retry-finalize"
    in
    Trajectory.record_entry acc entry;
    (match Trajectory.finalize acc Trajectory.Completed with
     | _ -> Alcotest.fail "blocked parent must make finalize observable"
     | exception Trajectory.Persistence_error _ -> ());
    Unix.unlink blocked_parent;
    Trajectory.flush_pending acc;
    let rows =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"retry-finalize"
    in
    Alcotest.(check int) "Tool row and terminal summary retried together" 2
      (List.length rows);
    let open Yojson.Safe.Util in
    Alcotest.(check string) "Tool output survived retry" "durable"
      (List.hd rows |> member "outcome" |> member "output" |> to_string);
    Alcotest.(check string) "summary follows Tool row" "trajectory_summary"
      (List.nth rows 1 |> member "type" |> to_string))

(* The accumulator persists the complete structured Thinking block. *)
let test_record_thinking_persists_untruncated () =
  with_tmpdir (fun dir ->
    let big = String.make 9000 'x' in
    let entry =
      match
        Trajectory.make_thinking_entry ~ts:1000.0
          ~ts_iso:"2026-06-09T00:00:00Z" ~turn:4 ~block_index:0
          ~block:
            (Agent_sdk.Types.Thinking
               { content = big; signature = Some "signature-exact" })
      with
      | Ok entry -> entry
      | Error error ->
          Alcotest.failf "invalid Thinking fixture: %s"
            (Trajectory.entry_decode_error_to_string error)
    in
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"th1" ~generation:0 ()
    in
    Trajectory.record_thinking acc entry;
    Trajectory.flush_pending acc;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th1" in
    Alcotest.(check int) "one thinking line" 1 (List.length lines);
    let open Yojson.Safe.Util in
    let row = List.hd lines in
    Alcotest.(check string) "type=thinking" "thinking" (row |> member "type" |> to_string);
    Alcotest.(check int) "content untruncated (9000B, not 2000 cap)" 9000
      (row |> member "block" |> member "thinking" |> to_string
       |> String.length);
    Alcotest.(check string) "signature persisted byte-exact" "signature-exact"
      (row |> member "block" |> member "signature" |> to_string);
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let test_accumulator_preserves_reasoning_tool_order () =
  with_tmpdir (fun dir ->
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"ordered" ~generation:0 ()
    in
    let thinking =
      match
        Trajectory.make_thinking_entry ~ts:1.0
          ~ts_iso:"2026-07-18T00:00:01Z" ~turn:1 ~block_index:0
          ~block:
            (Agent_sdk.Types.Thinking
               { content = "inspect source"; signature = Some "sig" })
      with
      | Ok entry -> entry
      | Error error ->
          Alcotest.failf "invalid Thinking fixture: %s"
            (Trajectory.entry_decode_error_to_string error)
    in
    let tool =
      make_tool_entry ~ts:2.0 ~ts_iso:"2026-07-18T00:00:02Z" ~turn:1
        ~round:1 ~tool_name:"tool_read" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "source") ~duration_ms:1
        ~execution_id:"exec-ordered-1"
    in
    Trajectory.record_thinking acc thinking;
    Trajectory.record_entry acc tool;
    Trajectory.finalize acc Trajectory.Completed |> ignore;
    let rows =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"ordered"
    in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "reasoning, Tool, summary" 3 (List.length rows);
    Alcotest.(check string) "reasoning stays before its Tool" "thinking"
      (List.nth rows 0 |> member "type" |> to_string);
    Alcotest.(check string) "Tool follows reasoning" "tool_read"
      (List.nth rows 1 |> member "tool_name" |> to_string);
    Alcotest.(check string) "summary remains terminal" "trajectory_summary"
      (List.nth rows 2 |> member "type" |> to_string))

(* persist_response_content stamps every block with the hook's ~turn (not
   acc.turn) and writes one line per thinking block, untruncated. *)
let test_persist_response_content_per_turn_full () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" ~generation:0 () in
    (* acc.turn stays 0; the hook passes ~turn:11 — assert ~turn wins. *)
    let big = String.make 5000 'a' in
    let detail : Agent_sdk.Types.reasoning_detail =
      { raw = `Assoc [ ("type", `String "reasoning.summary_text")
                     ; ("text", `String "detail text") ]
      ; text = Some "detail text"
      }
    in
    let content =
      [ Agent_sdk.Types.Thinking
          { signature = Some "signed-block"; content = big }
      ; Agent_sdk.Types.Thinking
          { signature = None; content = "second block" }
      ; Agent_sdk.Types.ReasoningDetails
          { reasoning_content = Some "reasoning content"; details = [ detail ] }
      ; Agent_sdk.Types.RedactedThinking "opaque-provider-payload"
      ]
    in
    Keeper_agent_run_thinking_trajectory.persist_response_content
      ~keeper_name:"k" ~trajectory_acc:(Some acc) ~turn:11 content;
    Trajectory.flush_pending acc;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "all reasoning block variants persisted" 4
      (List.length lines);
    List.iter (fun row ->
      Alcotest.(check int) "turn stamped from hook (11), not acc.turn (0)" 11
        (row |> member "turn" |> to_int)) lines;
    Alcotest.(check (list int)) "provider block order is explicit"
      [ 0; 1; 2; 3 ]
      (List.map (fun row -> row |> member "block_index" |> to_int) lines);
    Alcotest.(check int) "first block untruncated (5000B)" 5000
      (List.hd lines |> member "block" |> member "thinking" |> to_string
       |> String.length);
    Alcotest.(check string) "signed block signature survives" "signed-block"
      (List.hd lines |> member "block" |> member "signature" |> to_string);
    Alcotest.(check string) "reasoning_content survives" "reasoning content"
      (List.nth lines 2 |> member "block" |> member "reasoning_content"
       |> to_string);
    Alcotest.(check string) "reasoning detail raw JSON survives" "detail text"
      (List.nth lines 2 |> member "block" |> member "details" |> index 0
       |> member "text" |> to_string);
    Alcotest.(check string) "redacted opaque payload survives"
      "opaque-provider-payload"
      (List.nth lines 3 |> member "block" |> member "data" |> to_string);
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let () =
  Alcotest.run "Trajectory" [
    ("accumulator", [
      Alcotest.test_case "create" `Quick test_create_accumulator;
      Alcotest.test_case "duplicate active identity is rejected" `Quick
        test_duplicate_active_accumulator_is_rejected;
      Alcotest.test_case "record_entry" `Quick test_record_entry;
    ]);
    ("finalize", [
      Alcotest.test_case "finalize completed" `Quick test_finalize;
    ]);
    ("outcome", [
      Alcotest.test_case "outcome_to_string" `Quick test_outcome_to_string;
    ]);
    ("aggregate_tool_stats", [
      Alcotest.test_case "basic aggregation" `Quick test_aggregate_basic;
      Alcotest.test_case "with errors" `Quick test_aggregate_with_errors;
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
      Alcotest.test_case "required execution_id JSONL round-trip" `Quick
        test_execution_id_roundtrip;
      Alcotest.test_case "retired gate field is rejected" `Quick
        test_retired_gate_field_is_rejected;
      Alcotest.test_case "closed row codec rejects invalid fields and types"
        `Quick test_closed_row_codec_rejects_invalid_fields_and_types;
    ]);
    ("next_round", [
      Alcotest.test_case "empty or missing file -> 1" `Quick
        test_next_round_empty_or_missing_file;
      Alcotest.test_case "past turns only -> 1" `Quick
        test_next_round_past_turns_only;
      Alcotest.test_case "hydrates latest current round" `Quick
        test_next_round_hydrates_latest_current_round;
      Alcotest.test_case "concurrent cold miss remains unique" `Quick
        test_next_round_concurrent_cold_miss_is_unique;
      Alcotest.test_case "ignores summary rows without turn" `Quick
        test_next_round_ignores_summary_rows_without_turn;
      Alcotest.test_case "skips Thinking rows" `Quick
        test_next_round_skips_thinking_rows;
      Alcotest.test_case "cache identity includes masc_root" `Quick
        test_next_round_isolated_by_masc_root;
      Alcotest.test_case "uses latest persisted round" `Quick
        test_next_round_uses_latest_persisted_round;
      Alcotest.test_case "searches past non-Tool suffix" `Quick
        test_next_round_searches_past_non_tool_suffix;
      Alcotest.test_case "active allocator is monotonic" `Quick
        test_next_round_active_allocator_is_monotonic;
      Alcotest.test_case "evicts past-turn keys" `Quick
        test_next_round_evicts_past_turn_keys;
    ]);
    ("read_entries_since", [
      Alcotest.test_case "filter by timestamp" `Quick test_read_entries_since;
      Alcotest.test_case "rejects retired fields" `Quick
        test_read_entries_since_result_rejects_retired_fields;
      Alcotest.test_case "nonexistent directory" `Quick test_read_entries_since_no_dir;
      Alcotest.test_case "read_recent_lines/read_all_lines skip malformed rows" `Quick
        test_read_recent_lines_skips_malformed_rows;
      Alcotest.test_case "recent limit counts canonical entries" `Quick
        test_recent_limit_counts_only_canonical_entries;
      Alcotest.test_case "byte cursor is exact and snapshot-bound" `Quick
        test_recent_page_cursor_is_exact_and_snapshot_bound;
      Alcotest.test_case "byte cursor rejects truncated snapshot" `Quick
        test_recent_page_cursor_rejects_truncated_snapshot;
      Alcotest.test_case "recent reader scans non-entry suffix without cap" `Quick
        test_recent_reader_scans_unbounded_non_entry_suffix;
      Alcotest.test_case "summary row not counted as malformed" `Quick
        test_summary_row_not_counted_as_malformed;
    ]);
    ("thinking_trajectory", [
      Alcotest.test_case "tool results persist without display truncation" `Quick
        test_tool_results_are_persisted_untruncated;
      Alcotest.test_case "failed finalize retries Tool rows and summary" `Quick
        test_finalize_retries_complete_batch_after_write_failure;
      Alcotest.test_case "record_thinking persists canonical block" `Quick
        test_record_thinking_persists_untruncated;
      Alcotest.test_case "reasoning/Tool order is preserved" `Quick
        test_accumulator_preserves_reasoning_tool_order;
      Alcotest.test_case "persist_response_content stamps hook turn, all blocks" `Quick
        test_persist_response_content_per_turn_full;
    ]);
  ]
