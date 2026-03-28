open Alcotest

module Harness = Masc_mcp.Dashboard_harness_health
module Cal = Masc_mcp.Eval_calibration
module AR = Masc_mcp.Anti_rationalization

let test_counter = ref 0

let tmpdir prefix =
  incr test_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "%s_%d_%d_%d"
         prefix (Unix.getpid ()) !test_counter
         (int_of_float (Unix.gettimeofday () *. 1000.0)))
  in
  (try Unix.mkdir dir 0o755 with
   | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

let with_test_stores f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let verdict_dir = tmpdir "harness_verdicts" in
  let pre_dir = tmpdir "harness_pre" in
  let dna_dir = tmpdir "harness_dna" in
  Cal.set_store_for_testing ~base_dir:verdict_dir;
  Harness.set_pre_compact_store_for_testing ~base_dir:pre_dir;
  Harness.set_dna_quality_store_for_testing ~base_dir:dna_dir;
  Fun.protect
    ~finally:(fun () ->
      Cal.reset_store_for_testing ();
      Harness.reset_runtime_stores_for_testing ())
    f

let require_assoc key json =
  Yojson.Safe.Util.(json |> member key)

let today_string ?(offset_days = 0) () =
  let ts = Unix.gettimeofday () +. (float_of_int offset_days *. 86400.0) in
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

let make_req ?(title = "Task") ?(notes = "Detailed completion notes") () :
    AR.review_request =
  {
    task_title = title;
    task_description = "desc";
    completion_notes = notes;
    agent_name = "codex";
  }

let make_result ?(verdict = AR.Approve) ?(gate = "llm")
    ?fallback_reason () : AR.review_result =
  {
    verdict;
    evaluator_cascade = "cross_verifier";
    generator_cascade = None;
    gate;
    fallback_reason;
  }

let test_runtime_signals_are_persisted () =
  with_test_stores @@ fun () ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000
       ~strategies:[ "PruneToolOutputs"; "SummarizeOld" ]
       ~model_family:"verifier" ~trigger:"ratio(0.91>=0.85)");
  ignore
    (Harness.record_dna_quality ~keeper_name:"keeper-a" ~score:0.82
       ~dimensions:
         (`Assoc
           [
             ("has_goal_anchor", `Bool true);
             ("has_task_anchor", `Bool true);
             ("has_recent_context", `Bool true);
             ("truncation_artifacts", `Int 0);
             ("content_length", `Int 420);
           ]));
  let json = Harness.json () in
  let overview = require_assoc "overview" json in
  let pre_compact = require_assoc "pre_compact" json in
  let dna_quality = require_assoc "dna_quality" json in
  check string "pre status" "healthy"
    Yojson.Safe.Util.(pre_compact |> member "status" |> to_string);
  check string "dna status" "healthy"
    Yojson.Safe.Util.(dna_quality |> member "status" |> to_string);
  check string "overview pre status" "healthy"
    Yojson.Safe.Util.(overview |> member "pre_compact_status" |> to_string);
  check string "overview dna status" "healthy"
    Yojson.Safe.Util.(overview |> member "dna_status" |> to_string);
  check int "pre events count" 1
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "dna events count" 1
    Yojson.Safe.Util.(dna_quality |> member "recent_events" |> to_list |> List.length);
  check bool "last_signal_at present" true
    Yojson.Safe.Util.(overview |> member "last_signal_at" <> `Null)

let test_runtime_window_empty_reason () =
  with_test_stores @@ fun () ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~model_family:"verifier" ~trigger:"ratio(0.91>=0.85)");
  ignore
    (Harness.record_dna_quality ~keeper_name:"keeper-a" ~score:0.82
       ~dimensions:(`Assoc [ ("has_goal_anchor", `Bool true) ]));
  let tomorrow = today_string ~offset_days:1 () in
  let json = Harness.json ~since:tomorrow ~until:tomorrow () in
  let pre_compact = require_assoc "pre_compact" json in
  let dna_quality = require_assoc "dna_quality" json in
  check string "pre empty reason" "window_empty"
    Yojson.Safe.Util.(pre_compact |> member "empty_reason" |> to_string);
  check string "dna empty reason" "window_empty"
    Yojson.Safe.Util.(dna_quality |> member "empty_reason" |> to_string);
  check int "pre filtered empty" 0
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "dna filtered empty" 0
    Yojson.Safe.Util.(dna_quality |> member "recent_events" |> to_list |> List.length)

let test_runtime_stale_status () =
  with_test_stores @@ fun () ->
  let stale_timestamp = Time_compat.now () -. (31. *. 60.) in
  ignore
    (Harness.record_pre_compact_at ~timestamp:stale_timestamp
       ~keeper_name:"keeper-a" ~context_ratio:0.91 ~message_count:88
       ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~model_family:"verifier" ~trigger:"ratio(0.91>=0.85)");
  ignore
    (Harness.record_dna_quality_at ~timestamp:stale_timestamp
       ~keeper_name:"keeper-a" ~score:0.82
       ~dimensions:
         (`Assoc
           [
             ("has_goal_anchor", `Bool true);
             ("has_task_anchor", `Bool true);
             ("has_recent_context", `Bool true);
             ("truncation_artifacts", `Int 0);
           ]));
  let json = Harness.json () in
  let overview = require_assoc "overview" json in
  let pre_compact = require_assoc "pre_compact" json in
  let dna_quality = require_assoc "dna_quality" json in
  check string "pre stale" "stale"
    Yojson.Safe.Util.(pre_compact |> member "status" |> to_string);
  check string "dna stale" "stale"
    Yojson.Safe.Util.(dna_quality |> member "status" |> to_string);
  check string "overview pre stale" "stale"
    Yojson.Safe.Util.(overview |> member "pre_compact_status" |> to_string);
  check string "overview dna stale" "stale"
    Yojson.Safe.Util.(overview |> member "dna_status" |> to_string)

let test_overview_warns_when_evaluator_falls_back () =
  with_test_stores @@ fun () ->
  let req = make_req ~title:"Fallback task" () in
  let result =
    make_result ~gate:"fallback" ~fallback_reason:"judge timeout" ()
  in
  Cal.record_verdict ~task_id:"task-1" ~req ~result ();
  let json = Harness.json ~since:(today_string ()) ~until:(today_string ()) () in
  let overview = require_assoc "overview" json in
  check string "evaluator status" "warning"
    Yojson.Safe.Util.(overview |> member "evaluator_status" |> to_string);
  check (float 0.0001) "fallback ratio" 1.0
    Yojson.Safe.Util.(overview |> member "fallback_ratio" |> to_float)

let () =
  run "Dashboard_harness_health"
    [
      ( "runtime signals",
        [
          test_case "persisted runtime signals surface as healthy" `Quick
            test_runtime_signals_are_persisted;
          test_case "filtered windows explain empty runtime rails" `Quick
            test_runtime_window_empty_reason;
          test_case "stale runtime signals surface as stale" `Quick
            test_runtime_stale_status;
          test_case "fallback-heavy evaluator shows warning overview" `Quick
            test_overview_warns_when_evaluator_falls_back;
        ] );
    ]
