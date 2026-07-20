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

let tool_invocation ?(tool_use_id = "") ?(oas_turn = 0)
    ?(planned_index = 0) ?(batch_index = 0) ?(batch_size = 1)
    ?(execution_mode = Agent_sdk.Tool.Serial) () =
  Agent_sdk.Tool.Invocation.create ~tool_use_id ~turn:oas_turn
    ~schedule:{ planned_index; batch_index; batch_size; execution_mode }

let make_tool_entry ?(keeper_turn_id = 1) ?(oas_turn = 0)
    ?(planned_index = 0) ?(batch_index = 0) ?(batch_size = 1)
    ?(execution_mode = Agent_sdk.Tool.Serial) ?(tool_use_id = "") ~ts ~ts_iso
    ~tool_name ~arguments ~outcome ~duration_ms ~execution_id () =
  let invocation =
    tool_invocation ~tool_use_id ~oas_turn ~planned_index ~batch_index
      ~batch_size ~execution_mode ()
  in
  match
    Trajectory.make_tool_call_entry ~ts ~ts_iso ~keeper_turn_id ~invocation
      ~tool_name ~arguments ~outcome ~duration_ms
      ~execution_id:(Ids.Execution_id.of_string execution_id)
  with
  | Ok entry -> entry
  | Error error ->
      Alcotest.failf "invalid Tool fixture: %s"
        (Trajectory.entry_decode_error_to_string error)

let canonical_tool_row ?keeper_turn_id ?oas_turn ?planned_index ?batch_index
    ?batch_size ?execution_mode ?tool_use_id ~ts ~execution_id () =
  make_tool_entry ?keeper_turn_id ?oas_turn ?planned_index ?batch_index
    ?batch_size ?execution_mode ?tool_use_id ~ts
    ~ts_iso:"2026-07-01T00:00:00Z" ~tool_name:"tool_execute"
    ~arguments:[] ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:1
    ~execution_id ()
  |> Trajectory.entry_to_json
  |> Yojson.Safe.to_string

let test_create_accumulator () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-001" ~keeper_turn_id:1 ~generation:0 () in
    Alcotest.(check int) "exact keeper turn" 1
      (Trajectory.accumulator_keeper_turn_id acc);
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let test_duplicate_active_accumulator_is_rejected () =
  with_tmpdir (fun dir ->
    let first =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
        ~trace_id:"trace-duplicate" ~keeper_turn_id:1 ~generation:0 ()
    in
    (match
       Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
         ~trace_id:"trace-duplicate" ~keeper_turn_id:1 ~generation:0 ()
     with
     | _ -> Alcotest.fail "duplicate active accumulator must not replace SSOT"
     | exception
         Trajectory.Accumulator_registration_error
           (Trajectory.Active_accumulator_exists _) -> ());
    Trajectory.finalize first Trajectory.Completed |> ignore)

let test_active_observation_does_not_block_next_keeper_turn () =
  with_tmpdir (fun dir ->
    let first =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
        ~trace_id:"trace-shared" ~keeper_turn_id:1 ~generation:0 ()
    in
    let next =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"test-keeper"
        ~trace_id:"trace-shared" ~keeper_turn_id:2 ~generation:0 ()
    in
    Trajectory.finalize first Trajectory.Completed |> ignore;
    Trajectory.finalize next Trajectory.Completed |> ignore)

(* ================================================================ *)
(* Test: record_entry updates accumulator                            *)
(* ================================================================ *)

let test_record_entry () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-002" ~keeper_turn_id:1 ~generation:0 () in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-01-01T00:00:00Z"
        ~oas_turn:1 ~tool_name:"tool_execute"
        ~arguments:[ "command", `String "pwd" ]
        ~outcome:(Trajectory.Tool_succeeded "/home/test") ~duration_ms:50
        ~execution_id:"exec-1000-0001" ()
    in
    Trajectory.record_entry acc entry;
    let trajectory = Trajectory.finalize acc Trajectory.Completed in
    Alcotest.(check int) "Tool count" 1 trajectory.total_tool_calls)

(* ================================================================ *)
(* Test: finalize creates trajectory record                          *)
(* ================================================================ *)

let test_finalize () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-006" ~keeper_turn_id:1 ~generation:0 () in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-01-01T00:00:00Z"
        ~oas_turn:1 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:100
        ~execution_id:"exec-finalize-1" ()
    in
    Trajectory.record_entry acc entry;
    let thinking =
      match
        Trajectory.make_thinking_entry ~ts:1001.0
          ~ts_iso:"2026-01-01T00:00:01Z" ~keeper_turn_id:1 ~oas_turn:2
          ~block_index:0
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
      traj.Trajectory.observed_oas_turn_count;
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
  Alcotest.(check string) "input required" "input_required"
    (Trajectory.outcome_to_string Trajectory.Input_required);
  Alcotest.(check string) "cancelled" "cancelled"
    (Trajectory.outcome_to_string Trajectory.Cancelled)

(* ================================================================ *)
(* Test: aggregate_tool_stats                                        *)
(* ================================================================ *)

let mk_entry ?(ts = 1000.0) ?(error = None) name dur ts_iso =
  make_tool_entry ~ts ~ts_iso ~oas_turn:1 ~tool_name:name ~arguments:[]
    ~outcome:
      (match error with
       | None -> Trajectory.Tool_succeeded "ok"
       | Some message -> Trajectory.Tool_failed message)
    ~duration_ms:dur ~execution_id:(Printf.sprintf "exec-%s-%d" name dur) ()

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
    make_tool_entry ~ts:1000.0 ~ts_iso:"2026-04-06T10:00:00Z"
      ~keeper_turn_id:42 ~oas_turn:3 ~planned_index:7 ~batch_index:1
      ~batch_size:2 ~execution_mode:Agent_sdk.Tool.Concurrent
      ~tool_use_id:"provider-tool-1" ~tool_name:"tool_execute"
      ~arguments:[ "command", `String "pwd" ]
      ~outcome:(Trajectory.Tool_succeeded "/tmp/work") ~duration_ms:25
      ~execution_id:"exec-1000-0001" ()
  in
  let json = Trajectory.entry_to_json entry in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "structured argument" "pwd"
    (json |> member "args" |> member "command" |> to_string);
  Alcotest.(check string) "execution_id persisted" "exec-1000-0001"
    (json |> member "execution_id" |> to_string);
  Alcotest.(check string) "closed schema" "masc.keeper_trajectory.v1"
    (json |> member "schema" |> to_string);
  Alcotest.(check int) "Keeper clock" 42
    (json |> member "keeper_turn_id" |> to_int);
  Alcotest.(check int) "OAS clock" 3 (json |> member "oas_turn" |> to_int);
  Alcotest.(check int) "planned occurrence" 7
    (json |> member "schedule" |> member "planned_index" |> to_int);
  Alcotest.(check int) "batch placement" 1
    (json |> member "schedule" |> member "batch_index" |> to_int);
  Alcotest.(check int) "batch cardinality" 2
    (json |> member "schedule" |> member "batch_size" |> to_int);
  Alcotest.(check string) "execution mode" "concurrent"
    (json |> member "schedule" |> member "execution_mode" |> to_string);
  Alcotest.(check string) "opaque provider correlation" "provider-tool-1"
    (json |> member "tool_use_id" |> to_string)

(* The canonical join key is required. Rows without it are invalid rather than
   guessed from timestamps, names, or durations. *)
let test_execution_id_roundtrip () =
  let entry =
    make_tool_entry ~ts:1000.0 ~ts_iso:"2026-06-12T00:00:00Z"
      ~keeper_turn_id:3 ~oas_turn:2 ~tool_name:"tool_execute" ~arguments:[]
      ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:10
      ~execution_id:"exec-1718150400000-0001" ()
  in
  (match Trajectory.tool_call_entry_of_json (Trajectory.entry_to_json entry) with
   | Trajectory.Decoded_entry decoded ->
       Alcotest.(check string) "round-trip"
         "exec-1718150400000-0001"
         (Ids.Execution_id.to_string decoded.Trajectory.execution_id)
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

let test_schedule_and_tool_use_id_are_exact_observations () =
  let decode entry =
    match Trajectory.tool_call_entry_of_json (Trajectory.entry_to_json entry) with
    | Trajectory.Decoded_entry decoded -> decoded
    | Trajectory.Non_entry_row | Trajectory.Invalid_entry _ ->
        Alcotest.fail "canonical Tool entry did not decode"
  in
  let blank =
    make_tool_entry ~ts:1.0 ~ts_iso:"2026-07-18T00:00:00Z"
      ~planned_index:12 ~batch_index:99 ~batch_size:1
      ~execution_mode:Agent_sdk.Tool.Concurrent ~tool_use_id:""
      ~tool_name:"tool_execute" ~arguments:[]
      ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:0
      ~execution_id:"exec-blank-tool-use" ()
    |> decode
  in
  Alcotest.(check string) "blank provider correlation remains blank" ""
    blank.Trajectory.tool_use_id;
  Alcotest.(check int) "batch_index is observed, not normalized" 99
    blank.Trajectory.schedule.batch_index;
  let repeated tool_use_id execution_id =
    make_tool_entry ~ts:2.0 ~ts_iso:"2026-07-18T00:00:01Z" ~tool_use_id
      ~tool_name:"tool_execute" ~arguments:[]
      ~outcome:(Trajectory.Tool_succeeded "ok") ~duration_ms:0 ~execution_id ()
    |> decode
  in
  let first = repeated "provider-repeat" "exec-repeat-1" in
  let second = repeated "provider-repeat" "exec-repeat-2" in
  Alcotest.(check string) "repeated opaque id retained" first.tool_use_id
    second.tool_use_id;
  Alcotest.(check bool) "execution identity stays distinct" false
    (Ids.Execution_id.equal first.execution_id second.execution_id)

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
  check_invalid_field Trajectory.Keeper_turn_id
    (replace "keeper_turn_id" (`Int 0) valid_entry);
  check_invalid_field Trajectory.Oas_turn
    (replace "oas_turn" (`Int (-1)) valid_entry);
  let replace_schedule key value =
    match valid_entry with
    | `Assoc fields ->
        let schedule =
          match List.assoc "schedule" fields with
          | `Assoc schedule_fields ->
              `Assoc ((key, value) :: List.remove_assoc key schedule_fields)
          | _ -> Alcotest.fail "schedule must be an object"
        in
        `Assoc (("schedule", schedule) :: List.remove_assoc "schedule" fields)
    | _ -> Alcotest.fail "entry serializer must return an object"
  in
  check_invalid_field Trajectory.Planned_index
    (replace_schedule "planned_index" (`Int (-1)));
  check_invalid_field Trajectory.Batch_index
    (replace_schedule "batch_index" (`Int (-1)));
  check_invalid_field Trajectory.Batch_size
    (replace_schedule "batch_size" (`Int 0));
  check_invalid_field Trajectory.Execution_mode
    (replace_schedule "execution_mode" (`String "invented"));
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
    {|{"schema":"masc.keeper_trajectory.v1","type":"thinking","ts":1000.0,"ts_iso":"2026-06-12T00:00:00Z","keeper_turn_id":1,"oas_turn":0,"block_index":0,"block":{"type":"thinking","thinking":"thought"},"unexpected":false}|}
  in
  (match
     Trajectory.tool_call_entry_of_json
       (Yojson.Safe.from_string invalid_thinking)
   with
   | Trajectory.Invalid_entry
       (Trajectory.Unexpected_field "unexpected") -> ()
   | _ ->
       Alcotest.fail
         "tool-only reader must observe an invalid Thinking sibling row");
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
    let traj_dir = Trajectory.trajectories_dir masc_root keeper in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-100.jsonl" in
    let entry_json ts =
      canonical_tool_row ~ts
        ~execution_id:(Printf.sprintf "exec-read-%.0f" ts) ()
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
    let traj_dir = Trajectory.trajectories_dir masc_root keeper in
    Fs_compat.mkdir_p traj_dir;
    let path = Filename.concat traj_dir "trace-101.jsonl" in
    let rows =
      [
        canonical_tool_row ~ts:1000.0 ~execution_id:"exec-read-1" ();
        canonical_tool_row ~ts:2000.0 ~planned_index:1
          ~execution_id:"exec-read-2" ();
        (let canonical =
           canonical_tool_row ~ts:3000.0 ~planned_index:2
             ~execution_id:"exec-read-3" ()
           |> Yojson.Safe.from_string
         in
         match canonical with
         | `Assoc fields ->
             `Assoc (("round", `Int 3) :: fields) |> Yojson.Safe.to_string
         | _ -> Alcotest.fail "canonical fixture must be an object");
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

let standard_scan_limits = Trajectory.standard_trajectory_scan_limits

let test_read_recent_lines_skips_malformed_rows () =
  with_tmpdir (fun dir ->
    let acc =
      Trajectory.create_accumulator
        ~masc_root:dir ~keeper_name:"test-keeper" ~trace_id:"trace-malformed"
        ~keeper_turn_id:1 ~generation:0 ()
    in
    Trajectory.record_entry acc
      (mk_entry "tool_execute" 10 "2026-07-01T00:00:00Z");
    Trajectory.flush_pending acc;
    write_raw_line ~masc_root:dir ~keeper_name:"test-keeper"
      ~trace_id:"trace-malformed" "{not valid json";
    let recent_page =
      Trajectory.read_recent_lines_page_result ~masc_root:dir
        ~keeper_name:"test-keeper" ~trace_id:"trace-malformed"
        ~scan_limits:standard_scan_limits ~max_entries:100 ()
    in
    let recent = recent_page.Trajectory.read in
    Alcotest.(check int)
      "malformed row dropped, valid row kept (read_recent_lines)"
      1
      (List.length recent.Trajectory.lines);
    Alcotest.(check int) "recent malformed row observed" 1
      recent.Trajectory.line_decode.invalid_reasons.malformed_json;
    let tool_entries =
      Trajectory.read_entries_result ~masc_root:dir
        ~keeper_name:"test-keeper"
        ~trace_id:"trace-malformed"
    in
    Alcotest.(check int)
      "malformed row dropped, valid row kept (read_entries)"
      1
      (List.length tool_entries.Trajectory.entries);
    Alcotest.(check int) "tool-entry malformed row observed" 1
      tool_entries.Trajectory.decode.invalid_reasons.malformed_json;
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

let trajectory_tool_row ~ts ~planned_index ~execution_id =
  canonical_tool_row ~ts ~planned_index ~execution_id ()

let trajectory_thinking_row =
  {|{"schema":"masc.keeper_trajectory.v1","type":"thinking","ts":1001.0,"ts_iso":"2026-07-01T00:00:01Z","keeper_turn_id":1,"oas_turn":0,"block_index":0,"block":{"type":"thinking","thinking":"exact reasoning"}}|}

let trajectory_summary_row =
  {|{"schema":"masc.keeper_trajectory.v1","type":"trajectory_summary","keeper_name":"test-keeper","trace_id":"trace-page","keeper_turn_id":1,"generation":0,"observed_oas_turn_count":1,"total_tool_calls":2,"outcome":"completed","started_at":1000.0,"ended_at":1002.0}|}

let scan_limits ~physical_rows ~bytes =
  match
    Trajectory.make_trajectory_scan_limits
      ~max_physical_rows:physical_rows ~max_bytes:bytes
  with
  | Ok limits -> limits
  | Error error ->
      Alcotest.fail
        (Trajectory.trajectory_scan_limit_error_to_string error)

let tool_execution_ids lines =
  List.filter_map
    (function
      | Trajectory.Tool_call entry ->
          Some (Ids.Execution_id.to_string entry.Trajectory.execution_id)
      | Trajectory.Thinking _ -> None)
    lines

let check_execution_ids message expected lines =
  Alcotest.(check (list string)) message expected (tool_execution_ids lines)

let test_scan_limit_contract_is_typed () =
  (match
     Trajectory.make_trajectory_scan_limits ~max_physical_rows:0
       ~max_bytes:1L
   with
   | Error (Trajectory.Non_positive_physical_row_limit 0) -> ()
   | Ok _ | Error _ -> Alcotest.fail "zero physical-row limit must be typed");
  (match
     Trajectory.make_trajectory_scan_limits ~max_physical_rows:1
       ~max_bytes:0L
   with
   | Error (Trajectory.Non_positive_byte_limit 0L) -> ()
   | Ok _ | Error _ -> Alcotest.fail "zero byte limit must be typed");
  Alcotest.(check bool) "snapshot start is complete" true
    (Trajectory.trajectory_scan_coverage Trajectory.Reached_snapshot_start
     = Trajectory.Scan_complete);
  Alcotest.(check bool) "transport limit is partial" true
    (Trajectory.trajectory_scan_coverage
       Trajectory.Reached_physical_row_limit
     = Trajectory.Scan_partial);
  Alcotest.(check bool) "oversized row is blocked" true
    (Trajectory.trajectory_scan_coverage
       Trajectory.Blocked_by_oversized_physical_row
     = Trajectory.Scan_blocked)

let test_recent_limit_counts_only_canonical_entries () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-decoded-limit" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-oldest");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "{not valid json";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_summary_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_thinking_row;
    let result_page =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:standard_scan_limits ~max_entries:2 ()
    in
    let result = result_page.Trajectory.read in
    (match result.Trajectory.lines with
     | [ Trajectory.Tool_call tool; Trajectory.Thinking thinking ] ->
         Alcotest.(check string) "oldest canonical Tool"
           "exec-oldest"
           (Ids.Execution_id.to_string tool.Trajectory.execution_id);
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
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-page-1");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_thinking_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "{not valid json";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_summary_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1002.0 ~planned_index:1
         ~execution_id:"exec-page-2");
    let newest =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:standard_scan_limits ~max_entries:2 ()
    in
    (match newest.Trajectory.read.lines with
     | [ Trajectory.Thinking _; Trajectory.Tool_call tool ] ->
         Alcotest.(check string) "newest Tool identity"
           "exec-page-2"
           (Ids.Execution_id.to_string tool.Trajectory.execution_id)
     | lines ->
         Alcotest.failf "expected Thinking + newest Tool, got %d rows"
           (List.length lines));
    Alcotest.(check int) "page observes summary" 1
      newest.Trajectory.read.line_decode.skipped_summary_count;
    Alcotest.(check int) "page observes malformed row" 1
      newest.Trajectory.read.line_decode.invalid_line_count;
    Alcotest.(check bool) "entry bound is the exact stop reason" true
      (newest.Trajectory.scan.stop = Trajectory.Reached_entry_limit);
    let cursor =
      match newest.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "older canonical row requires a cursor"
    in
    Alcotest.(check bool) "cursor is a positive byte boundary" true
      (Trajectory.trajectory_byte_cursor_offset cursor > 0L);
    (* Appends after the first page do not move its cursor into the new suffix. *)
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1003.0 ~planned_index:2
         ~execution_id:"exec-later");
    let older =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~scan_limits:standard_scan_limits
        ~max_entries:2 ()
    in
    (match older.Trajectory.read.lines with
     | [ Trajectory.Tool_call tool ] ->
         Alcotest.(check string) "older page Tool identity"
           "exec-page-1"
           (Ids.Execution_id.to_string tool.Trajectory.execution_id)
     | lines ->
         Alcotest.failf "expected one older Tool, got %d rows"
           (List.length lines));
    Alcotest.(check bool) "beginning of snapshot has no next cursor" true
      (Option.is_none older.Trajectory.next_cursor);
    Alcotest.(check bool) "older page covers the snapshot prefix" true
      (older.Trajectory.scan.stop = Trajectory.Reached_snapshot_start);
    Alcotest.(check int) "cursor page has no storage error" 0
      (List.length older.Trajectory.read.io_errors))

let test_recent_page_cursor_rejects_truncated_snapshot () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-truncated-cursor" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-truncate-1");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1001.0 ~planned_index:1
         ~execution_id:"exec-truncate-2");
    let first =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:standard_scan_limits ~max_entries:1 ()
    in
    let cursor =
      match first.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "first page must expose its older byte boundary"
    in
    Unix.truncate (Trajectory.trajectory_path dir keeper_name trace_id) 0;
    let rejected =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~scan_limits:standard_scan_limits
        ~max_entries:1 ()
    in
    Alcotest.(check int) "truncated page has no fabricated rows" 0
      (List.length rejected.Trajectory.read.lines);
    Alcotest.(check int) "truncation is an explicit storage error" 1
      (List.length rejected.Trajectory.read.io_errors);
    Alcotest.(check bool) "truncated cursor is explicitly rejected" true
      (rejected.Trajectory.scan.stop = Trajectory.Rejected_cursor);
    Alcotest.(check bool) "failed page has no continuation cursor" true
      (Option.is_none rejected.Trajectory.next_cursor))

let test_physical_row_limit_pages_without_skip_or_duplicate () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-physical-row-page" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-physical-old");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id trajectory_summary_row;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "{not valid json";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id "";
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1001.0 ~planned_index:1
         ~execution_id:"exec-physical-new");
    let limits = scan_limits ~physical_rows:3 ~bytes:1_000_000L in
    let newest =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:limits ~max_entries:10 ()
    in
    check_execution_ids "newest bounded page" [ "exec-physical-new" ]
      newest.Trajectory.read.lines;
    Alcotest.(check int) "blank and invalid rows consume physical allowance" 3
      newest.Trajectory.scan.physical_rows;
    Alcotest.(check int) "invalid row remains observable" 1
      newest.Trajectory.read.line_decode.invalid_line_count;
    Alcotest.(check bool) "physical-row bound stops the scan" true
      (newest.Trajectory.scan.stop = Trajectory.Reached_physical_row_limit);
    let cursor =
      match newest.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "physical-row stop requires a safe cursor"
    in
    let older =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~scan_limits:limits ~max_entries:10 ()
    in
    check_execution_ids "older bounded page" [ "exec-physical-old" ]
      older.Trajectory.read.lines;
    Alcotest.(check int) "summary remains explicitly observed" 1
      older.Trajectory.read.line_decode.skipped_summary_count;
    Alcotest.(check bool) "older page reaches snapshot start" true
      (older.Trajectory.scan.stop = Trajectory.Reached_snapshot_start);
    check_execution_ids "concatenated pages neither skip nor duplicate"
      [ "exec-physical-old"; "exec-physical-new" ]
      (older.Trajectory.read.lines @ newest.Trajectory.read.lines))

let test_standard_reader_stops_at_non_entry_transport_boundary () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-default-transport-boundary" in
    let trajectory_dir = Trajectory.trajectories_dir dir keeper_name in
    Fs_compat.mkdir_p trajectory_dir;
    let path = Trajectory.trajectory_path dir keeper_name trace_id in
    let output = open_out_bin path in
    let physical_row_limit =
      Trajectory.standard_trajectory_scan_limits.max_physical_rows
    in
    Fun.protect
      ~finally:(fun () -> close_out output)
      (fun () ->
         output_string output
           (trajectory_tool_row ~ts:1000.0 ~planned_index:0
              ~execution_id:"exec-before-default-boundary");
         output_char output '\n';
         for _ = 1 to physical_row_limit do
           output_string output trajectory_summary_row;
           output_char output '\n'
         done);
    let page =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:standard_scan_limits ~max_entries:1 ()
    in
    Alcotest.(check int) "older canonical row is outside this bounded page" 0
      (List.length page.Trajectory.read.lines);
    Alcotest.(check int) "default physical rows are observed exactly"
      physical_row_limit page.Trajectory.scan.physical_rows;
    Alcotest.(check int) "all inspected summaries remain observable"
      physical_row_limit
      page.Trajectory.read.line_decode.skipped_summary_count;
    Alcotest.(check bool) "default request ends at its transport boundary" true
      (page.Trajectory.scan.stop = Trajectory.Reached_physical_row_limit);
    Alcotest.(check bool) "default boundary has an exact continuation" true
      (Option.is_some page.Trajectory.next_cursor))

let test_byte_limit_pages_at_safe_newline_boundary () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-byte-page" in
    let oldest =
      trajectory_tool_row ~ts:1000.0 ~planned_index:0
        ~execution_id:"exec-byte-old"
    in
    let middle =
      trajectory_tool_row ~ts:1001.0 ~planned_index:1
        ~execution_id:"exec-byte-middle"
    in
    let newest =
      trajectory_tool_row ~ts:1002.0 ~planned_index:2
        ~execution_id:"exec-byte-new"
    in
    List.iter
      (write_raw_line ~masc_root:dir ~keeper_name ~trace_id)
      [ oldest; middle; newest ];
    let byte_limit =
      Int64.of_int (String.length middle + 1 + String.length newest + 1)
    in
    let first_limits = scan_limits ~physical_rows:100 ~bytes:byte_limit in
    let first =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:first_limits ~max_entries:10 ()
    in
    check_execution_ids "only the fully observed newest row is decoded"
      [ "exec-byte-new" ] first.Trajectory.read.lines;
    Alcotest.(check int64) "actual read bytes equal the byte contract"
      byte_limit first.Trajectory.scan.bytes_read;
    Alcotest.(check bool) "byte contract is the exact stop reason" true
      (first.Trajectory.scan.stop = Trajectory.Reached_byte_limit);
    let cursor =
      match first.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "safe newline boundary requires a cursor"
    in
    let older_limits = scan_limits ~physical_rows:100 ~bytes:1_000_000L in
    let older =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:cursor ~scan_limits:older_limits ~max_entries:10 ()
    in
    check_execution_ids "partial middle row is re-read, not lost"
      [ "exec-byte-old"; "exec-byte-middle" ] older.Trajectory.read.lines;
    check_execution_ids "byte pages neither skip nor duplicate"
      [ "exec-byte-old"; "exec-byte-middle"; "exec-byte-new" ]
      (older.Trajectory.read.lines @ first.Trajectory.read.lines))

let test_oversized_physical_row_is_explicitly_blocked () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-oversized-row" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-oversized");
    let limits = scan_limits ~physical_rows:100 ~bytes:8L in
    let page =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:limits ~max_entries:10 ()
    in
    Alcotest.(check int) "no partial row is decoded" 0
      (List.length page.Trajectory.read.lines);
    Alcotest.(check int) "no complete physical row was observed" 0
      page.Trajectory.scan.physical_rows;
    Alcotest.(check int64) "actual partial bytes remain observable" 8L
      page.Trajectory.scan.bytes_read;
    Alcotest.(check bool) "oversized row has a distinct stop reason" true
      (page.Trajectory.scan.stop
       = Trajectory.Blocked_by_oversized_physical_row);
    Alcotest.(check bool) "blocked page has no fabricated cursor" true
      (Option.is_none page.Trajectory.next_cursor);
    Alcotest.(check int) "transport blockage is not a storage error" 0
      (List.length page.Trajectory.read.io_errors))

let cursor_token_of_json json =
  json |> Yojson.Safe.to_string
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let cursor_json_fields = function
  | `Assoc fields -> fields
  | _ -> Alcotest.fail "cursor fixture must be an object"

let canonical_cursor_json ?(schema =
    "masc.keeper_trajectory_cursor." ^ Trajectory.trajectory_contract_version)
    ?(keeper_name = "test-keeper") ?(trace_id = "trace-cursor-codec")
    ?(snapshot_device = "1") ?(snapshot_inode = "2")
    ?(snapshot_size = "10") ?(before_byte = "5") () =
  `Assoc
    [ "schema", `String schema
    ; "keeper_name", `String keeper_name
    ; "trace_id", `String trace_id
    ; "snapshot_device", `String snapshot_device
    ; "snapshot_inode", `String snapshot_inode
    ; "snapshot_size", `String snapshot_size
    ; "before_byte", `String before_byte
    ]

let test_cursor_codec_is_url_safe_closed_and_logically_bound () =
  with_tmpdir (fun dir ->
    let keeper_name = "test-keeper" in
    let trace_id = "trace-cursor-codec" in
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1000.0 ~planned_index:0
         ~execution_id:"exec-cursor-old");
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id
      (trajectory_tool_row ~ts:1001.0 ~planned_index:1
         ~execution_id:"exec-cursor-new");
    let first =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~scan_limits:standard_scan_limits ~max_entries:1 ()
    in
    let cursor =
      match first.Trajectory.next_cursor with
      | Some cursor -> cursor
      | None -> Alcotest.fail "entry-limited page must expose a cursor"
    in
    let encoded = Trajectory.trajectory_byte_cursor_to_string cursor in
    let is_uri_safe = function
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' -> true
      | _ -> false
    in
    Alcotest.(check bool) "cursor is unpadded URI-safe Base64" true
      (encoded <> "" && String.for_all is_uri_safe encoded);
    let decoded =
      match Trajectory.trajectory_byte_cursor_of_string encoded with
      | Ok cursor -> cursor
      | Error error ->
          Alcotest.fail
            (Trajectory.trajectory_cursor_decode_error_to_string error)
    in
    Alcotest.(check string) "cursor codec is stable" encoded
      (Trajectory.trajectory_byte_cursor_to_string decoded);
    Alcotest.(check int64) "cursor offset round-trips"
      (Trajectory.trajectory_byte_cursor_offset cursor)
      (Trajectory.trajectory_byte_cursor_offset decoded);
    let cursor_json =
      match
        Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet encoded
      with
      | Error (`Msg message) -> Alcotest.fail message
      | Ok payload -> Yojson.Safe.from_string payload
    in
    let forged_before_byte =
      Int64.pred (Trajectory.trajectory_byte_cursor_offset decoded)
    in
    let forged_token =
      cursor_json
      |> cursor_json_fields
      |> List.remove_assoc "before_byte"
      |> (fun fields ->
        `Assoc
          (("before_byte", `String (Int64.to_string forged_before_byte))
           :: fields))
      |> cursor_token_of_json
    in
    let forged_cursor =
      match Trajectory.trajectory_byte_cursor_of_string forged_token with
      | Ok cursor -> cursor
      | Error error ->
          Alcotest.fail
            (Trajectory.trajectory_cursor_decode_error_to_string error)
    in
    let rejected_boundary =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id ~before:forged_cursor ~scan_limits:standard_scan_limits
        ~max_entries:1 ()
    in
    Alcotest.(check bool) "cursor must point to a verified newline boundary"
      true
      (rejected_boundary.Trajectory.scan.stop = Trajectory.Rejected_cursor);
    Alcotest.(check int64) "cursor boundary validation I/O is observed" 1L
      rejected_boundary.Trajectory.scan.bytes_read;
    write_raw_line ~masc_root:dir ~keeper_name ~trace_id:"other-trace"
      (trajectory_tool_row ~ts:1002.0 ~planned_index:0
         ~execution_id:"exec-other-trace");
    let rejected =
      Trajectory.read_recent_lines_page_result ~masc_root:dir ~keeper_name
        ~trace_id:"other-trace" ~before:decoded
        ~scan_limits:standard_scan_limits ~max_entries:1 ()
    in
    Alcotest.(check bool) "cursor cannot cross a logical trace boundary" true
      (rejected.Trajectory.scan.stop = Trajectory.Rejected_cursor);
    Alcotest.(check int) "logical mismatch is explicit" 1
      (List.length rejected.Trajectory.read.io_errors));
  (match Trajectory.trajectory_byte_cursor_of_string "not-a-cursor!" with
   | Error Trajectory.Cursor_base64_decode_failed -> ()
   | Ok _ | Error _ -> Alcotest.fail "invalid Base64 must be typed");
  (match
     canonical_cursor_json ~schema:"retired.cursor.schema" ()
     |> cursor_token_of_json
     |> Trajectory.trajectory_byte_cursor_of_string
   with
   | Error (Trajectory.Cursor_invalid_field Trajectory.Cursor_schema) -> ()
   | Ok _ | Error _ -> Alcotest.fail "unknown cursor schema must be rejected");
  (match
     canonical_cursor_json ()
     |> cursor_json_fields
     |> (fun fields -> `Assoc (("extra", `String "x") :: fields))
     |> cursor_token_of_json
     |> Trajectory.trajectory_byte_cursor_of_string
   with
   | Error (Trajectory.Cursor_unexpected_field "extra") -> ()
   | Ok _ | Error _ -> Alcotest.fail "unexpected cursor field must be rejected");
  (match
     canonical_cursor_json ()
     |> cursor_json_fields
     |> (fun fields -> `Assoc (List.remove_assoc "before_byte" fields))
     |> cursor_token_of_json
     |> Trajectory.trajectory_byte_cursor_of_string
   with
   | Error (Trajectory.Cursor_missing_field Trajectory.Cursor_before_byte) -> ()
   | Ok _ | Error _ -> Alcotest.fail "missing cursor field must be typed");
  (match
     canonical_cursor_json ()
     |> cursor_json_fields
     |> (fun fields -> `Assoc (("before_byte", `String "5") :: fields))
     |> cursor_token_of_json
     |> Trajectory.trajectory_byte_cursor_of_string
   with
   | Error (Trajectory.Cursor_duplicate_field "before_byte") -> ()
   | Ok _ | Error _ -> Alcotest.fail "duplicate cursor field must be typed");
  match
    canonical_cursor_json ~snapshot_size:"10" ~before_byte:"11" ()
    |> cursor_token_of_json
    |> Trajectory.trajectory_byte_cursor_of_string
  with
  | Error (Trajectory.Cursor_invalid_field Trajectory.Cursor_before_byte) -> ()
  | Ok _ | Error _ -> Alcotest.fail "cursor offset beyond snapshot must fail"

(* trajectory_summary rows are intentionally written to the same JSONL file at
   session end; they must not inflate the "malformed JSON or unrecognized
   shape" skip counter that the dashboard read paths log. *)
let test_summary_row_not_counted_as_malformed () =
  let lines =
    [
      canonical_tool_row ~ts:1000.0 ~execution_id:"exec-summary-1" ()
    ; {|{"schema":"masc.keeper_trajectory.v1","type":"trajectory_summary","keeper_name":"k","trace_id":"t","keeper_turn_id":1,"generation":0,"observed_oas_turn_count":0,"total_tool_calls":0,"outcome":"completed","started_at":0.0,"ended_at":0.0}|}
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
(* Test: thinking trajectory — full untruncated text, per-turn        *)
(* ================================================================ *)

let read_thinking_jsonl ~masc_root ~keeper_name ~trace_id =
  let path = Trajectory.trajectory_path masc_root keeper_name trace_id in
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
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-07-18T00:00:00Z"
        ~keeper_turn_id:1 ~oas_turn:0 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded result) ~duration_ms:10
        ~execution_id:"exec-lossless-1" ()
    in
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"tool-lossless" ~keeper_turn_id:1 ~generation:0 ()
    in
    Trajectory.record_entry acc entry;
    Trajectory.flush_pending acc;
    let persisted =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"tool-lossless"
    in
    let open Yojson.Safe.Util in
    let persisted_result =
      match persisted with
      | [ row ] -> row |> member "outcome" |> member "output" |> to_string
      | _ -> Alcotest.fail "expected exactly one persisted tool row"
    in
    Alcotest.(check string) "Keeper-lane append is lossless" result
      persisted_result;
    Trajectory.finalize acc Trajectory.Completed |> ignore)

let test_finalize_retries_complete_batch_after_write_failure () =
  with_tmpdir (fun dir ->
    let blocked_parent = Filename.concat dir "keepers" in
    let oc = open_out blocked_parent in
    close_out oc;
    let acc =
      Trajectory.create_accumulator ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"retry-finalize" ~keeper_turn_id:1 ~generation:0 ()
    in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-07-18T00:00:00Z"
        ~keeper_turn_id:1 ~oas_turn:0 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "durable") ~duration_ms:10
        ~execution_id:"exec-retry-finalize" ()
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

let test_flush_error_observer_reserved_exception_propagates () =
  with_tmpdir (fun dir ->
    let blocked_parent = Filename.concat dir "keepers" in
    let oc = open_out blocked_parent in
    close_out oc;
    let acc =
      Trajectory.create_accumulator
        ~on_flush_error:(fun _ -> raise Sys.Break)
        ~masc_root:dir ~keeper_name:"k" ~trace_id:"reserved-flush"
        ~keeper_turn_id:1 ~generation:0 ()
    in
    let entry =
      make_tool_entry ~ts:1000.0 ~ts_iso:"2026-07-18T00:00:00Z"
        ~keeper_turn_id:1 ~oas_turn:0 ~tool_name:"tool_execute" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "durable") ~duration_ms:10
        ~execution_id:"exec-reserved-flush" ()
    in
    Trajectory.record_entry acc entry;
    (match Trajectory.finalize acc Trajectory.Completed with
     | _ -> Alcotest.fail "reserved observer exception must propagate"
     | exception Sys.Break -> ());
    Unix.unlink blocked_parent;
    Trajectory.flush_pending acc;
    let rows =
      read_thinking_jsonl ~masc_root:dir ~keeper_name:"k"
        ~trace_id:"reserved-flush"
    in
    Alcotest.(check int)
      "reserved failure leaves the complete batch retryable"
      2 (List.length rows))

(* The accumulator persists the complete structured Thinking block. *)
let test_record_thinking_persists_untruncated () =
  with_tmpdir (fun dir ->
    let big = String.make 9000 'x' in
    let entry =
      match
        Trajectory.make_thinking_entry ~ts:1000.0
          ~ts_iso:"2026-06-09T00:00:00Z" ~keeper_turn_id:4 ~oas_turn:2
          ~block_index:0
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
        ~trace_id:"th1" ~keeper_turn_id:4 ~generation:0 ()
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
        ~trace_id:"ordered" ~keeper_turn_id:1 ~generation:0 ()
    in
    let thinking =
      match
        Trajectory.make_thinking_entry ~ts:1.0
          ~ts_iso:"2026-07-18T00:00:01Z" ~keeper_turn_id:1 ~oas_turn:0
          ~block_index:0
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
      make_tool_entry ~ts:2.0 ~ts_iso:"2026-07-18T00:00:02Z"
        ~keeper_turn_id:1 ~oas_turn:0 ~tool_name:"tool_read" ~arguments:[]
        ~outcome:(Trajectory.Tool_succeeded "source") ~duration_ms:1
        ~execution_id:"exec-ordered-1" ()
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

(* persist_response_content stamps each block with the exact accumulator
   Keeper clock and OAS callback clock. *)
let test_persist_response_content_per_turn_full () =
  with_tmpdir (fun dir ->
    let acc = Trajectory.create_accumulator
      ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" ~keeper_turn_id:7
      ~generation:0 () in
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
      ~keeper_name:"k" ~trajectory_acc:(Some acc) ~oas_turn:11 content;
    Trajectory.flush_pending acc;
    let lines = read_thinking_jsonl ~masc_root:dir ~keeper_name:"k" ~trace_id:"th2" in
    let open Yojson.Safe.Util in
    Alcotest.(check int) "all reasoning block variants persisted" 4
      (List.length lines);
    List.iter (fun row ->
      Alcotest.(check int) "exact Keeper clock" 7
        (row |> member "keeper_turn_id" |> to_int);
      Alcotest.(check int) "exact OAS clock" 11
        (row |> member "oas_turn" |> to_int)) lines;
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
      Alcotest.test_case "active observation does not block next Keeper turn"
        `Quick test_active_observation_does_not_block_next_keeper_turn;
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
      Alcotest.test_case "schedule and tool_use_id remain exact observations"
        `Quick test_schedule_and_tool_use_id_are_exact_observations;
      Alcotest.test_case "retired gate field is rejected" `Quick
        test_retired_gate_field_is_rejected;
      Alcotest.test_case "closed row codec rejects invalid fields and types"
        `Quick test_closed_row_codec_rejects_invalid_fields_and_types;
    ]);
    ("read_entries_since", [
      Alcotest.test_case "filter by timestamp" `Quick test_read_entries_since;
      Alcotest.test_case "rejects retired fields" `Quick
        test_read_entries_since_result_rejects_retired_fields;
      Alcotest.test_case "nonexistent directory" `Quick test_read_entries_since_no_dir;
      Alcotest.test_case "read_recent_lines/read_all_lines skip malformed rows" `Quick
        test_read_recent_lines_skips_malformed_rows;
      Alcotest.test_case "scan-limit contract and coverage are typed" `Quick
        test_scan_limit_contract_is_typed;
      Alcotest.test_case "recent limit counts canonical entries" `Quick
        test_recent_limit_counts_only_canonical_entries;
      Alcotest.test_case "byte cursor is exact and snapshot-bound" `Quick
        test_recent_page_cursor_is_exact_and_snapshot_bound;
      Alcotest.test_case "byte cursor rejects truncated snapshot" `Quick
        test_recent_page_cursor_rejects_truncated_snapshot;
      Alcotest.test_case "physical-row pages preserve exact coverage" `Quick
        test_physical_row_limit_pages_without_skip_or_duplicate;
      Alcotest.test_case "default reader stops at non-entry transport boundary"
        `Quick test_standard_reader_stops_at_non_entry_transport_boundary;
      Alcotest.test_case "byte pages stop at safe newline boundaries" `Quick
        test_byte_limit_pages_at_safe_newline_boundary;
      Alcotest.test_case "oversized physical row is explicitly blocked" `Quick
        test_oversized_physical_row_is_explicitly_blocked;
      Alcotest.test_case "cursor codec is closed and logically bound" `Quick
        test_cursor_codec_is_url_safe_closed_and_logically_bound;
      Alcotest.test_case "summary row not counted as malformed" `Quick
        test_summary_row_not_counted_as_malformed;
    ]);
    ("thinking_trajectory", [
      Alcotest.test_case "tool results persist without display truncation" `Quick
        test_tool_results_are_persisted_untruncated;
      Alcotest.test_case "failed finalize retries Tool rows and summary" `Quick
        test_finalize_retries_complete_batch_after_write_failure;
      Alcotest.test_case "reserved flush observer exception propagates" `Quick
        test_flush_error_observer_reserved_exception_propagates;
      Alcotest.test_case "record_thinking persists canonical block" `Quick
        test_record_thinking_persists_untruncated;
      Alcotest.test_case "reasoning/Tool order is preserved" `Quick
        test_accumulator_preserves_reasoning_tool_order;
      Alcotest.test_case "persist_response_content stamps exact clocks" `Quick
        test_persist_response_content_per_turn_full;
    ]);
  ]
