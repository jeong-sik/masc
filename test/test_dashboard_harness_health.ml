open Alcotest

module Harness = Masc_mcp.Dashboard_harness_health
module Cal = Masc_mcp.Eval_calibration
module AR = Masc_mcp.Anti_rationalization
module Coord = Masc_mcp.Coord
module Reg = Masc_mcp.Keeper_registry
module Keeper_types = Masc_mcp.Keeper_types

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
  let base_dir = tmpdir "harness_room" in
  let verdict_dir = tmpdir "harness_verdicts" in
  let pre_dir = tmpdir "harness_pre" in
  let config = Coord.default_config base_dir in
  ignore (Coord.init config ~agent_name:None);
  Cal.set_store_for_testing ~base_dir:verdict_dir;
  Harness.set_pre_compact_store_for_testing ~base_dir:pre_dir;
  Fun.protect
    ~finally:(fun () ->
      Cal.reset_store_for_testing ();
      Harness.reset_runtime_stores_for_testing ())
    (fun () -> f config)

let make_keeper_meta ?(name = "keeper-a") ?(trace_id = "trace-keeper-a") () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String trace_id);
          ("cascade_name", `String Masc_mcp.(Keeper_config.default_cascade_name ()));
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta_of_json failed: " ^ err)

let write_keeper_meta config meta =
  match Keeper_types.write_meta config meta with
  | Ok () -> ()
  | Error err -> Alcotest.fail ("write_meta failed: " ^ err)

let record_handoff_metric ?(timestamp = Time_compat.now ()) ?(keeper_name = "keeper-a")
    ?(trace_id = "trace-keeper-a") ?(generation = 0) ?next_generation
    ?prev_trace_id ?new_trace_id ?to_model config =
  let meta = make_keeper_meta ~name:keeper_name ~trace_id () in
  write_keeper_meta config meta;
  let keeper_name = meta.name in
  let handoff_fields =
    [ ("performed", `Bool true) ]
    @ (match next_generation with
      | Some value -> [ ("to_generation", `Int value) ]
      | None -> [])
    @ (match prev_trace_id with
      | Some value -> [ ("prev_trace_id", `String value) ]
      | None -> [])
    @ (match new_trace_id with
      | Some value -> [ ("new_trace_id", `String value) ]
      | None -> [])
    @ (match to_model with
      | Some value -> [ ("to_model", `String value) ]
      | None -> [])
  in
  let metrics_store = Keeper_types.keeper_metrics_store config keeper_name in
  Dated_jsonl.append metrics_store
    (`Assoc
      [
        ("ts_unix", `Float timestamp);
        ("name", `String keeper_name);
        ("trace_id", `String trace_id);
        ("generation", `Int generation);
        ("handoff", `Assoc handoff_fields);
      ])

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

let make_result ?(verdict = AR.Approve) ?(gate = AR.Structured_tool)
    ?fallback_reason () : AR.review_result =
  {
    verdict;
    evaluator_cascade = "cross_verifier";
    generator_cascade = None;
    gate;
    fallback_reason;
  }

let append_verdict_record ~timestamp ~agent_name ~task_id ~verdict ?fallback_reason () =
  Dated_jsonl.append (Cal.get_store ())
    (`Assoc
      ([
         ("record_type", `String "verdict");
         ("notes_hash", `String ("hash-" ^ task_id));
         ("task_id", `String task_id);
         ("task_title", `String ("Task " ^ task_id));
         ("agent_name", `String agent_name);
         ("verdict", `String verdict);
         ("gate", `String "structured_tool");
         ("evaluator_cascade", `String "cross_verifier");
         ("timestamp", `Float timestamp);
       ]
       @
       match fallback_reason with
       | Some reason -> [ ("fallback_reason", `String reason) ]
       | None -> []))

let test_runtime_signals_are_persisted () =
  with_test_stores @@ fun config ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000
       ~strategies:[ "PruneToolOutputs"; "SummarizeOld" ]
       ~context_window:200_000 ~is_local_model:false ~trigger:"ratio(0.91>=0.85)");
  record_handoff_metric config ~next_generation:1
    ~prev_trace_id:"trace-keeper-a"
    ~new_trace_id:"trace-keeper-a-next"
    ~to_model:"llama:auto";
  let json = Harness.json ~config () in
  let overview = require_assoc "overview" json in
  let pre_compact = require_assoc "pre_compact" json in
  let recent_handoffs = require_assoc "recent_handoffs" json in
  check string "pre status" "healthy"
    Yojson.Safe.Util.(pre_compact |> member "status" |> to_string);
  check string "handoff status" "healthy"
    Yojson.Safe.Util.(recent_handoffs |> member "status" |> to_string);
  check string "overview pre status" "healthy"
    Yojson.Safe.Util.(overview |> member "pre_compact_status" |> to_string);
  check string "overview handoff status" "healthy"
    Yojson.Safe.Util.(overview |> member "handoff_status" |> to_string);
  check int "pre events count" 1
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "handoff events count" 1
    Yojson.Safe.Util.(recent_handoffs |> member "recent_events" |> to_list |> List.length);
  check bool "last_signal_at present" true
    Yojson.Safe.Util.(overview |> member "last_signal_at" <> `Null)

let test_runtime_window_empty_reason () =
  with_test_stores @@ fun config ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~context_window:200_000 ~is_local_model:false ~trigger:"ratio(0.91>=0.85)");
  record_handoff_metric config ~next_generation:1
    ~prev_trace_id:"trace-keeper-a"
    ~new_trace_id:"trace-keeper-a-next";
  let tomorrow = today_string ~offset_days:1 () in
  let json = Harness.json ~config ~since:tomorrow ~until:tomorrow () in
  let pre_compact = require_assoc "pre_compact" json in
  let recent_handoffs = require_assoc "recent_handoffs" json in
  check string "pre empty reason" "window_empty"
    Yojson.Safe.Util.(pre_compact |> member "empty_reason" |> to_string);
  check string "handoff empty reason" "window_empty"
    Yojson.Safe.Util.(recent_handoffs |> member "empty_reason" |> to_string);
  check int "pre filtered empty" 0
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "handoff filtered empty" 0
    Yojson.Safe.Util.(recent_handoffs |> member "recent_events" |> to_list |> List.length)

let test_runtime_since_only_window_empty_reason () =
  with_test_stores @@ fun config ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~context_window:200_000 ~is_local_model:false ~trigger:"ratio(0.91>=0.85)");
  record_handoff_metric config ~next_generation:1
    ~prev_trace_id:"trace-keeper-a"
    ~new_trace_id:"trace-keeper-a-next";
  let tomorrow = today_string ~offset_days:1 () in
  let json = Harness.json ~config ~since:tomorrow () in
  let pre_compact = require_assoc "pre_compact" json in
  let recent_handoffs = require_assoc "recent_handoffs" json in
  check string "pre empty reason (since only)" "window_empty"
    Yojson.Safe.Util.(pre_compact |> member "empty_reason" |> to_string);
  check string "handoff empty reason (since only)" "window_empty"
    Yojson.Safe.Util.(recent_handoffs |> member "empty_reason" |> to_string);
  check int "pre filtered empty (since only)" 0
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "handoff filtered empty (since only)" 0
    Yojson.Safe.Util.(recent_handoffs |> member "recent_events" |> to_list |> List.length)

let test_runtime_until_only_window_empty_reason () =
  with_test_stores @@ fun config ->
  ignore
    (Harness.record_pre_compact ~keeper_name:"keeper-a" ~context_ratio:0.91
       ~message_count:88 ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~context_window:200_000 ~is_local_model:false ~trigger:"ratio(0.91>=0.85)");
  record_handoff_metric config ~next_generation:1
    ~prev_trace_id:"trace-keeper-a"
    ~new_trace_id:"trace-keeper-a-next";
  let yesterday = today_string ~offset_days:(-1) () in
  let json = Harness.json ~config ~until:yesterday () in
  let pre_compact = require_assoc "pre_compact" json in
  let recent_handoffs = require_assoc "recent_handoffs" json in
  check string "pre empty reason (until only)" "window_empty"
    Yojson.Safe.Util.(pre_compact |> member "empty_reason" |> to_string);
  check string "handoff empty reason (until only)" "window_empty"
    Yojson.Safe.Util.(recent_handoffs |> member "empty_reason" |> to_string);
  check int "pre filtered empty (until only)" 0
    Yojson.Safe.Util.(pre_compact |> member "recent_events" |> to_list |> List.length);
  check int "handoff filtered empty (until only)" 0
    Yojson.Safe.Util.(recent_handoffs |> member "recent_events" |> to_list |> List.length)

let test_runtime_stale_status () =
  with_test_stores @@ fun config ->
  let stale_timestamp = Time_compat.now () -. (31. *. 60.) in
  ignore
    (Harness.record_pre_compact_at ~timestamp:stale_timestamp
       ~keeper_name:"keeper-a" ~context_ratio:0.91 ~message_count:88
       ~token_count:32000 ~strategies:[ "PruneToolOutputs" ]
       ~context_window:200_000 ~is_local_model:false ~trigger:"ratio(0.91>=0.85)");
  record_handoff_metric ~timestamp:stale_timestamp config ~next_generation:1
    ~prev_trace_id:"trace-keeper-a"
    ~new_trace_id:"trace-keeper-a-next";
  let json = Harness.json ~config () in
  let overview = require_assoc "overview" json in
  let pre_compact = require_assoc "pre_compact" json in
  let recent_handoffs = require_assoc "recent_handoffs" json in
  check string "pre stale" "stale"
    Yojson.Safe.Util.(pre_compact |> member "status" |> to_string);
  check string "handoff stale" "stale"
    Yojson.Safe.Util.(recent_handoffs |> member "status" |> to_string);
  check string "overview pre stale" "stale"
    Yojson.Safe.Util.(overview |> member "pre_compact_status" |> to_string);
  check string "overview handoff stale" "stale"
    Yojson.Safe.Util.(overview |> member "handoff_status" |> to_string)

let test_overview_warns_when_evaluator_falls_back () =
  with_test_stores @@ fun config ->
  let req = make_req ~title:"Fallback task" () in
  let result =
    make_result ~gate:AR.Fallback ~fallback_reason:"judge timeout" ()
  in
  Cal.record_verdict ~task_id:"task-1" ~req ~result ();
  let json =
    Harness.json ~config ~since:(today_string ()) ~until:(today_string ()) ()
  in
  let overview = require_assoc "overview" json in
  check string "evaluator status" "warning"
    Yojson.Safe.Util.(overview |> member "evaluator_status" |> to_string);
  check (float 0.0001) "fallback ratio" 1.0
    Yojson.Safe.Util.(overview |> member "fallback_ratio" |> to_float)

let test_agent_scoped_verdicts_filter_before_limit () =
  with_test_stores @@ fun _config ->
  append_verdict_record
    ~timestamp:100.0
    ~agent_name:"keeper-a"
    ~task_id:"keeper-1"
    ~verdict:"approve"
    ();
  append_verdict_record
    ~timestamp:101.0
    ~agent_name:"keeper-agent"
    ~task_id:"keeper-2"
    ~verdict:"reject:schema_violation"
    ();
  for i = 0 to 9 do
    append_verdict_record
      ~timestamp:(200.0 +. float_of_int i)
      ~agent_name:"other-agent"
      ~task_id:(Printf.sprintf "other-%d" i)
      ~verdict:"reject"
      ~fallback_reason:"timeout"
      ()
  done;
  let global_latest =
    Harness.read_recent_verdicts ~limit:1 ()
  in
  check string "global latest is other agent" "other-agent"
    (match global_latest with
     | verdict :: _ -> verdict.agent_name
     | [] -> failwith "expected global verdict");
  let scoped =
    Harness.read_recent_verdicts_for_agents
      ~limit:5
      ~agent_names:[ "keeper-a"; "keeper-agent" ]
      ()
  in
  check int "scoped verdict count survives global crowding" 2 (List.length scoped);
  check string "scoped latest verdict agent alias" "keeper-agent"
    (match scoped with
     | verdict :: _ -> verdict.agent_name
     | [] -> failwith "expected scoped verdict");
  let outcomes =
    Masc_mcp.Dashboard_http_keeper.compute_outcomes_rollup
      ~keeper_name:"keeper-a"
      ~agent_name:"keeper-agent"
      ~recent_crash_count:0
      ~registry_entry:None
  in
  check int "outcomes pass count uses scoped helper" 1
    Yojson.Safe.Util.(outcomes |> member "validation" |> member "oas_verdicts" |> member "pass" |> to_int);
  check int "outcomes fail count parses reject variants" 1
    Yojson.Safe.Util.(outcomes |> member "validation" |> member "oas_verdicts" |> member "fail" |> to_int);
  check int "outcomes unknown count stays zero" 0
    Yojson.Safe.Util.(outcomes |> member "validation" |> member "oas_verdicts" |> member "unknown" |> to_int);
  check (list string) "failure reasons parse reject suffix"
    [ "schema_violation" ]
    Yojson.Safe.Util.(outcomes |> member "validation" |> member "oas_verdicts"
      |> member "top_failure_reasons" |> to_list |> filter_string);
  check (option (float 0.000_001)) "last verdict timestamp preserved" (Some 101.0)
    Yojson.Safe.Util.(outcomes |> member "validation" |> member "last_verdict_at" |> to_float_option)

let test_outcomes_rollup_counts_gate_rejected_from_completed_turns () =
  with_test_stores @@ fun config ->
  let keeper_name = "keeper-outcomes-gate" in
  let meta = make_keeper_meta ~name:keeper_name () in
  Reg.clear ();
  ignore (Reg.register ~base_path:config.base_path keeper_name meta);
  Reg.mark_turn_started ~base_path:config.base_path keeper_name;
  Reg.set_turn_decision_stage
    ~base_path:config.base_path keeper_name Reg.Decision_tool_policy_selected;
  Reg.mark_turn_gate_rejected_by_name keeper_name;
  Reg.mark_turn_finished ~base_path:config.base_path keeper_name;
  Reg.mark_turn_started ~base_path:config.base_path keeper_name;
  Reg.set_turn_decision_stage
    ~base_path:config.base_path keeper_name Reg.Decision_tool_policy_selected;
  Reg.set_turn_cascade_state
    ~base_path:config.base_path keeper_name (Reg.Packed Reg.Cascade_done);
  Reg.mark_turn_finished ~base_path:config.base_path keeper_name;
  Reg.mark_turn_started ~base_path:config.base_path keeper_name;
  Reg.set_turn_decision_stage
    ~base_path:config.base_path keeper_name Reg.Decision_tool_policy_selected;
  Reg.set_turn_cascade_state
    ~base_path:config.base_path keeper_name (Reg.Packed Reg.Cascade_exhausted);
  Reg.mark_turn_finished ~base_path:config.base_path keeper_name;
  let outcomes =
    Masc_mcp.Dashboard_http_keeper.compute_outcomes_rollup
      ~keeper_name
      ~agent_name:keeper_name
      ~recent_crash_count:0
      ~registry_entry:(Reg.get ~base_path:config.base_path keeper_name)
  in
  check int "observed turns comes from completed turn ring" 3
    Yojson.Safe.Util.(outcomes |> member "observed_turns" |> to_int);
  check int "gate_rejected bucket populated" 1
    Yojson.Safe.Util.(outcomes |> member "failures" |> member "gate_rejected" |> to_int);
  check int "substantive turns exclude gate_rejected" 1
    Yojson.Safe.Util.(outcomes |> member "successes" |> member "substantive_turns" |> to_int);
  check int "turn_failed bucket keeps non-gate failures" 1
    Yojson.Safe.Util.(outcomes |> member "failures" |> member "turn_failed" |> to_int)

(* ------------------------------------------------------------------ *)
(* Wake-time payload telemetry (Phase 0 for Option C redesign).       *)
(* ------------------------------------------------------------------ *)

let with_wake_payload_store f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = tmpdir "harness_wake_payload" in
  Harness.set_wake_payload_store_for_testing ~base_dir;
  Fun.protect
    ~finally:(fun () -> Harness.reset_runtime_stores_for_testing ())
    (fun () -> f ())

let sample_role_counts =
  [ ("system", 1); ("user", 6); ("assistant", 18); ("tool", 17) ]

let test_wake_payload_round_trip () =
  with_wake_payload_store @@ fun () ->
  let before =
    Harness.record_wake_payload
      ~keeper_name:"engineering-01"
      ~trace_id:"trc_abc"
      ~turn_index:3
      ~model_id:"claude-opus-4-7"
      ~context_window:200_000
      ~approx_body_bytes:184_231
      ~system_prompt_bytes:12_400
      ~tool_defs_bytes:48_200
      ~messages_bytes:123_631
      ~message_count:42
      ~role_counts:sample_role_counts
      ~tool_count:23
      ~has_compact_happened:false
  in
  let events = Harness.read_wake_payload_events () in
  check int "exactly one event persisted" 1 (List.length events);
  let after = List.hd events in
  check string "keeper_name round-trip" before.keeper_name after.keeper_name;
  check string "trace_id round-trip" before.trace_id after.trace_id;
  check int "turn_index round-trip" before.turn_index after.turn_index;
  check string "model_id round-trip" before.model_id after.model_id;
  check int "context_window round-trip"
    before.context_window after.context_window;
  check int "approx_body_bytes round-trip"
    before.approx_body_bytes after.approx_body_bytes;
  check int "system_prompt_bytes round-trip"
    before.system_prompt_bytes after.system_prompt_bytes;
  check int "tool_defs_bytes round-trip"
    before.tool_defs_bytes after.tool_defs_bytes;
  check int "messages_bytes round-trip"
    before.messages_bytes after.messages_bytes;
  check int "message_count round-trip"
    before.message_count after.message_count;
  check int "tool_count round-trip" before.tool_count after.tool_count;
  check bool "has_compact_happened round-trip"
    before.has_compact_happened after.has_compact_happened;
  let sorted =
    List.sort (fun (a, _) (b, _) -> compare a b)
  in
  check
    (list (pair string int))
    "role_counts round-trip"
    (sorted sample_role_counts)
    (sorted after.role_counts)

let test_wake_payload_role_count_invariant () =
  with_wake_payload_store @@ fun () ->
  let role_counts = [ ("user", 3); ("assistant", 5); ("tool", 2) ] in
  let message_count =
    List.fold_left (fun acc (_, n) -> acc + n) 0 role_counts
  in
  let event =
    Harness.record_wake_payload
      ~keeper_name:"k"
      ~trace_id:"t"
      ~turn_index:0
      ~model_id:"m"
      ~context_window:100_000
      ~approx_body_bytes:1_024
      ~system_prompt_bytes:256
      ~tool_defs_bytes:128
      ~messages_bytes:640
      ~message_count
      ~role_counts
      ~tool_count:0
      ~has_compact_happened:false
  in
  let total_from_counts =
    List.fold_left (fun acc (_, n) -> acc + n) 0 event.role_counts
  in
  check int "role_counts sum equals message_count"
    event.message_count total_from_counts

let test_wake_payload_empty_history () =
  with_wake_payload_store @@ fun () ->
  let event =
    Harness.record_wake_payload
      ~keeper_name:"k"
      ~trace_id:"t"
      ~turn_index:0
      ~model_id:"m"
      ~context_window:100_000
      ~approx_body_bytes:1_024
      ~system_prompt_bytes:1_024
      ~tool_defs_bytes:0
      ~messages_bytes:0
      ~message_count:0
      ~role_counts:[]
      ~tool_count:0
      ~has_compact_happened:false
  in
  check int "empty history message_count is zero" 0 event.message_count;
  check (list (pair string int)) "empty history role_counts is empty"
    [] event.role_counts;
  let events = Harness.read_wake_payload_events () in
  check int "empty-history event still persists" 1 (List.length events)

let test_wake_payload_filters_foreign_records () =
  with_wake_payload_store @@ fun () ->
  (* Directly append a pre_compact-style record into the wake_payload
     store to prove [wake_payload_event_of_json] rejects it. *)
  Dated_jsonl.append
    (Harness.get_wake_payload_store ())
    (`Assoc
      [
        ("record_type", `String "pre_compact");
        ("timestamp", `Float 1745000000.0);
        ("keeper_name", `String "intruder");
      ]);
  ignore
    (Harness.record_wake_payload
       ~keeper_name:"k" ~trace_id:"t" ~turn_index:0 ~model_id:"m"
       ~context_window:100_000 ~approx_body_bytes:0 ~system_prompt_bytes:0
       ~tool_defs_bytes:0 ~messages_bytes:0 ~message_count:0 ~role_counts:[]
       ~tool_count:0 ~has_compact_happened:false);
  let events = Harness.read_wake_payload_events () in
  check int "foreign record_type filtered out" 1 (List.length events);
  check string "only wake_payload survives" "k"
    (List.hd events).keeper_name

let () =
  run "Dashboard_harness_health"
    [
      ( "runtime signals",
        [
          test_case "persisted runtime signals surface as healthy" `Quick
            test_runtime_signals_are_persisted;
          test_case "filtered windows explain empty runtime rails" `Quick
            test_runtime_window_empty_reason;
          test_case "since-only windows stay stable" `Quick
            test_runtime_since_only_window_empty_reason;
          test_case "until-only windows stay stable" `Quick
            test_runtime_until_only_window_empty_reason;
          test_case "stale runtime signals surface as stale" `Quick
            test_runtime_stale_status;
          test_case "fallback-heavy evaluator shows warning overview" `Quick
            test_overview_warns_when_evaluator_falls_back;
          test_case "agent-scoped verdicts filter before limit" `Quick
            test_agent_scoped_verdicts_filter_before_limit;
          test_case "outcomes rollup counts gate_rejected from completed turns"
            `Quick test_outcomes_rollup_counts_gate_rejected_from_completed_turns;
        ] );
      ( "wake payload telemetry",
        [
          test_case "round-trip preserves every field" `Quick
            test_wake_payload_round_trip;
          test_case "role_counts sum equals message_count" `Quick
            test_wake_payload_role_count_invariant;
          test_case "empty history persists with zero counts" `Quick
            test_wake_payload_empty_history;
          test_case "non-wake_payload records ignored" `Quick
            test_wake_payload_filters_foreign_records;
        ] );
    ]
